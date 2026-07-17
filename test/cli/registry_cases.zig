//! Registry metadata tests for the pancake CLI (ADR-0084).
const std = @import("std");
const cli = @import("cli");
const pancake = @import("pancake");

test "everyday verbs are discoverable" {
    try std.testing.expect(cli.registry.find("listen") != null);
    try std.testing.expect(cli.registry.find("dial") != null);
    try std.testing.expect(cli.registry.find("probe") != null);
    try std.testing.expect(cli.registry.find("call") != null);
    try std.testing.expect(cli.registry.find("tell") != null);
    try std.testing.expect(cli.registry.find("fetch") != null);
    try std.testing.expect(cli.registry.find("introspect") == null);
    try std.testing.expect(cli.registry.find("nope") == null);
}

test "mcp catalog is policy-driven" {
    const listen = cli.registry.find("listen").?;
    try std.testing.expect(listen.mcp_never);
    try std.testing.expect(!cli.registry.mcpVisible(listen, .default));
    try std.testing.expect(!cli.registry.mcpVisible(listen, .full));
    try std.testing.expect(!cli.registry.mcpVisible(listen, .readonly));

    const dial = cli.registry.find("dial").?;
    try std.testing.expect(cli.registry.mcpVisible(dial, .default));
    try std.testing.expect(cli.registry.mcpVisible(dial, .full));
    try std.testing.expect(!cli.registry.mcpVisible(dial, .readonly));

    const close = cli.registry.find("close").?;
    try std.testing.expect(cli.registry.mcpVisible(close, .default));
    try std.testing.expect(cli.registry.mcpVisible(close, .full));

    const info = cli.registry.find("info").?;
    try std.testing.expect(cli.registry.mcpVisible(info, .readonly));
    try std.testing.expect(cli.registry.mcpVisible(info, .default));

    const locator = cli.registry.find("locator").?;
    try std.testing.expect(locator.argv_only);
    try std.testing.expect(locator.mcp_never);
    try std.testing.expect(!cli.registry.mcpVisible(locator, .readonly));
    try std.testing.expect(!cli.registry.mcpVisible(locator, .default));
    try std.testing.expect(!cli.registry.leafVisible(locator, .repl));
    try std.testing.expect(!cli.registry.leafVisible(listen, .repl));
    try std.testing.expect(cli.registry.leafVisible(dial, .repl));
}

test "mapActErr maps settle timeout to exit timeout not protocol_abort" {
    try std.testing.expectEqual(cli.exit_codes.timeout, cli.ocapn.mapActErr(error.WaitTimedOut));
    try std.testing.expectEqual(cli.exit_codes.timeout, cli.ocapn.mapActErr(error.HandshakeTimedOut));
    try std.testing.expectEqual(cli.exit_codes.protocol_abort, cli.ocapn.mapActErr(error.UnexpectedMessage));
}

test "exit codes are distinct" {
    try std.testing.expect(cli.exit_codes.ok == 0);
    try std.testing.expect(cli.exit_codes.internal == 1);
    try std.testing.expect(cli.exit_codes.usage == 2);
    try std.testing.expect(cli.exit_codes.identity == 3);
    try std.testing.expect(cli.exit_codes.dial == 4);
    try std.testing.expect(cli.exit_codes.protocol_abort == 5);
    try std.testing.expect(cli.exit_codes.timeout == 6);
    try std.testing.expect(cli.exit_codes.busy == 7);
}

test "mcp default catalog names exclude listen and include dial" {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.testing.allocator);
    for (&cli.registry.commands) |*cmd| {
        if (!cli.registry.mcpVisible(cmd, .default)) continue;
        try names.append(std.testing.allocator, cmd.name);
    }
    try std.testing.expect(names.items.len > 0);
    for (names.items) |n| {
        try std.testing.expect(!std.mem.eql(u8, n, "listen"));
    }
    var saw_dial = false;
    for (names.items) |n| {
        if (std.mem.eql(u8, n, "dial")) saw_dial = true;
    }
    try std.testing.expect(saw_dial);
}

test "tree ocapn leaves project the sole CapTP registry" {
    const leaves = cli.tree.ocapnLeaves();
    try std.testing.expectEqual(cli.registry.commands.len, leaves.len);
    for (cli.registry.commands, leaves) |reg, leaf| {
        try std.testing.expectEqualStrings(reg.name, leaf.name);
        try std.testing.expectEqualStrings(reg.help, leaf.short_help);
        try std.testing.expect(reg.run == leaf.run.?);
        try std.testing.expect(reg.flags.ptr == leaf.flags.ptr);
        try std.testing.expect(reg.positionals.ptr == leaf.positionals.ptr);
    }
}

test "tree has pancake griddle placeholder with status" {
    const griddle = cli.tree.root.findChild("griddle") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!griddle.isLeaf());
    const status = griddle.findChild("status") orelse return error.TestUnexpectedResult;
    try std.testing.expect(status.run != null);
    const help = griddle.findChild("help") orelse return error.TestUnexpectedResult;
    try std.testing.expect(help.run != null);
}

test "mcp tools/list body is valid JSON and excludes listen" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try cli.mcp.appendToolsListBody(&body, gpa, "2", .default);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body.items, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    try std.testing.expect(tools.items.len > 0);
    var saw_dial = false;
    var saw_close = false;
    for (tools.items) |t| {
        const name = t.object.get("name").?.string;
        try std.testing.expect(!std.mem.eql(u8, name, "listen"));
        if (std.mem.eql(u8, name, "dial")) saw_dial = true;
        if (std.mem.eql(u8, name, "close")) saw_close = true;
        _ = t.object.get("inputSchema") orelse return error.TestUnexpectedResult;
    }
    try std.testing.expect(saw_dial);
    try std.testing.expect(saw_close);
    try std.testing.expect(std.mem.endsWith(u8, body.items, "]}}"));
}

test "mcp tools/call result body is valid JSON (root braces closed)" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    // CapTP --json bodies end with a newline; embedding must stay one NDJSON line.
    try cli.mcp.appendToolsCallResult(&body, gpa, "7", "{\"ok\":true}\n", false);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body.items, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expect(result.get("isError").?.bool == false);
    const text = result.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings("{\"ok\":true}\n", text);
    try std.testing.expect(std.mem.endsWith(u8, body.items, "}}"));
}

test "json CapTP failure writes non-empty sink body (MCP/argv --json)" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(gpa);
    var c = cli.ctx.Ctx{
        .io = threaded.io(),
        .gpa = gpa,
        .environ = &environ,
        .front = .mcp,
        .json = .json,
        .sink = .{ .buffer = &capture },
        .secret = pancake.foundation.crypto.SecretKey.fromSeed([_]u8{9} ** 32),
    };
    defer c.deinit();

    const loc = [_][]const u8{"ocapn://127.0.0.1%3A1.tcp"};
    var parsed = cli.cmd_types.Parsed{ .gpa = gpa, .positionals = &loc };
    defer parsed.deinit();
    const code = try cli.ocapn.cmdProbe(&c, &parsed);
    try std.testing.expect(code != cli.exit_codes.ok);
    try std.testing.expect(capture.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "\"error\"") != null);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try cli.mcp.appendToolsCallResult(&body, gpa, "9", capture.items, true);
    const msg = try std.json.parseFromSlice(std.json.Value, gpa, body.items, .{});
    defer msg.deinit();
    const result = msg.value.object.get("result").?.object;
    try std.testing.expect(result.get("isError").?.bool);
    const text = result.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(text.len > 0);
}

test "mcp inputSchema projects front-applicable flags only" {
    const dial = cli.registry.find("dial").?;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try cli.mcp_schema.appendInputSchema(&out, std.testing.allocator, dial);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"locator\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"repl\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"args\"") == null);
}

test "mcp fillParsed maps named locator and legacy args" {
    const dial = cli.registry.find("dial").?;
    {
        const raw =
            \\{"locator":"ocapn://127.0.0.1%3A9.tcp","repl":true}
        ;
        const msg = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
        defer msg.deinit();
        var parsed: cli.cmd_types.Parsed = undefined;
        try cli.mcp_schema.fillParsed(std.testing.allocator, dial, msg.value, &parsed);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.positionals.len);
        try std.testing.expectEqualStrings("ocapn://127.0.0.1%3A9.tcp", parsed.positionals[0]);
        // --repl is argv-only; MCP fill must not accept it.
        try std.testing.expect(!parsed.flagBool("repl"));
    }
    {
        const raw =
            \\{"args":["ocapn://legacy.tcp"]}
        ;
        const msg = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
        defer msg.deinit();
        var parsed: cli.cmd_types.Parsed = undefined;
        try cli.mcp_schema.fillParsed(std.testing.allocator, dial, msg.value, &parsed);
        defer parsed.deinit();
        try std.testing.expectEqualStrings("ocapn://legacy.tcp", parsed.positionals[0]);
    }
}

test "mcp call inputSchema exposes named locator/name/verb/args" {
    const call = cli.registry.find("call").?;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try cli.mcp_schema.appendInputSchema(&out, std.testing.allocator, call);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"locator\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"verb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"args\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"required\":[\"name\",\"verb\"]") != null);
}

test "mcp fillParsed maps named call fields and legacy args bag" {
    const call = cli.registry.find("call").?;
    {
        const raw =
            \\{"locator":"ocapn://127.0.0.1%3A9.tcp","name":"greeter","verb":"greet","args":["world"]}
        ;
        const msg = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
        defer msg.deinit();
        var parsed: cli.cmd_types.Parsed = undefined;
        try cli.mcp_schema.fillParsed(std.testing.allocator, call, msg.value, &parsed);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 4), parsed.positionals.len);
        try std.testing.expectEqualStrings("ocapn://127.0.0.1%3A9.tcp", parsed.positionals[0]);
        try std.testing.expectEqualStrings("greeter", parsed.positionals[1]);
        try std.testing.expectEqualStrings("greet", parsed.positionals[2]);
        try std.testing.expectEqualStrings("world", parsed.positionals[3]);
    }
    {
        const raw =
            \\{"args":["ocapn://legacy.tcp","greeter","greet","world"]}
        ;
        const msg = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
        defer msg.deinit();
        var parsed: cli.cmd_types.Parsed = undefined;
        try cli.mcp_schema.fillParsed(std.testing.allocator, call, msg.value, &parsed);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 4), parsed.positionals.len);
        try std.testing.expectEqualStrings("ocapn://legacy.tcp", parsed.positionals[0]);
        try std.testing.expectEqualStrings("greeter", parsed.positionals[1]);
    }
}

test "REPL everyday help matches Tab CapTP set" {
    const gpa = std.testing.allocator;
    var help_buf: std.ArrayList(u8) = .empty;
    defer help_buf.deinit(gpa);
    const HelpW = struct {
        list: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
        pub fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.list.appendSlice(self.gpa, bytes);
        }
        pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
            try self.list.print(self.gpa, fmt, args);
        }
    };
    try cli.registry.helpEveryday(HelpW{ .list = &help_buf, .gpa = gpa }, .repl);
    // Row format is `  {name:<10}  …` — substring "locator" also appears in dial help.
    try std.testing.expect(std.mem.indexOf(u8, help_buf.items, "  listen    ") == null);
    try std.testing.expect(std.mem.indexOf(u8, help_buf.items, "  locator   ") == null);
    try std.testing.expect(std.mem.indexOf(u8, help_buf.items, "  dial      ") != null);
    for (cli.registry.commands) |cmd| {
        const row_prefix = try std.fmt.allocPrint(gpa, "  {s:<10}  ", .{cmd.name});
        defer gpa.free(row_prefix);
        const in_help = std.mem.indexOf(u8, help_buf.items, row_prefix) != null;
        try std.testing.expectEqual(cli.registry.leafVisible(&cmd, .repl), in_help);
    }
}

test "registry dispatch unknown verb is usage" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = cli.ctx.Ctx{
        .io = threaded.io(),
        .gpa = gpa,
        .environ = &environ,
        .front = .argv,
        .secret = @import("pancake").foundation.crypto.SecretKey.fromSeed([_]u8{9} ** 32),
    };
    defer c.deinit();
    const code = try cli.registry.dispatch(&c, "no-such-verb", &.{});
    try std.testing.expectEqual(cli.exit_codes.usage, code);
}
