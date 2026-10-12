//! XDG / POSIX / human-help goldens for the glowcap CLI.
const std = @import("std");
const cli = @import("cli");

const Command = cli.cmd_types.Command;
const Flag = cli.cmd_types.Flag;
const Positional = cli.cmd_types.Positional;

fn stubRun(ctx: *cli.ctx.Ctx, parsed: *cli.cmd_types.Parsed) anyerror!u8 {
    _ = ctx;
    _ = parsed;
    return cli.exit_codes.ok;
}

fn echoDashDashRun(ctx: *cli.ctx.Ctx, parsed: *cli.cmd_types.Parsed) anyerror!u8 {
    _ = ctx;
    try std.testing.expectEqual(@as(usize, 1), parsed.positionals.len);
    try std.testing.expectEqualStrings("--nope", parsed.positionals[0]);
    return cli.exit_codes.ok;
}

const root_flags = [_]Flag{
    .{ .long = "json", .help = "JSON", .persistent = true },
};
const children = [_]Command{
    .{
        .name = "echo",
        .short_help = "Echo positionals",
        .positionals = &[_]Positional{.{ .name = "args", .help = "tokens", .variadic = true, .required = false }},
        .run = stubRun,
    },
    .{
        .name = "version",
        .short_help = "Version",
        .aliases = &[_][]const u8{ "--version", "-V" },
        .run = stubRun,
    },
};
const fixture_root: Command = .{
    .name = "glowcap",
    .short_help = "fixture",
    .flags = &root_flags,
    .children = &children,
};

const dash_children = [_]Command{
    .{
        .name = "echo",
        .short_help = "Echo positionals",
        .positionals = &[_]Positional{.{ .name = "args", .help = "tokens", .variadic = true, .required = false }},
        .run = echoDashDashRun,
    },
};
const dash_root: Command = .{
    .name = "glowcap",
    .short_help = "fixture",
    .children = &dash_children,
};

test "defaultStateDir prefers GLOWCAP_STATE then XDG_STATE_HOME" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("HOME", "/home/tester");
    try environ.put("XDG_STATE_HOME", "/xdg/state");

    var buf: [256]u8 = undefined;
    const with_xdg = try cli.xdg.defaultStateDir(&buf, &environ, .product);
    try std.testing.expectEqualStrings("/xdg/state/glowcap", with_xdg);

    try environ.put("GLOWCAP_STATE", "/explicit/state");
    const with_env = try cli.xdg.defaultStateDir(&buf, &environ, .product);
    try std.testing.expectEqualStrings("/explicit/state", with_env);
}

test "empty XDG_STATE_HOME falls through like unset" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("HOME", "/home/tester");
    try environ.put("XDG_STATE_HOME", "");

    var buf: [256]u8 = undefined;
    const path = try cli.xdg.defaultStateDir(&buf, &environ, .product);
    try std.testing.expectEqualStrings("/home/tester/.local/state/glowcap", path);
}

test "defaultStateDir falls back to ~/.local/state/glowcap" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("HOME", "/home/tester");

    var buf: [256]u8 = undefined;
    const path = try cli.xdg.defaultStateDir(&buf, &environ, .product);
    try std.testing.expectEqualStrings("/home/tester/.local/state/glowcap", path);
}

test "mcp state posture defaults to .local/glowcap-mcp-state" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("HOME", "/home/tester");
    try environ.put("XDG_STATE_HOME", "/xdg/state");

    var buf: [256]u8 = undefined;
    const path = try cli.xdg.defaultStateDir(&buf, &environ, .mcp_local);
    try std.testing.expectEqualStrings(".local/glowcap-mcp-state", path);

    try environ.put("GLOWCAP_STATE", "/explicit/mcp");
    const override = try cli.xdg.defaultStateDir(&buf, &environ, .mcp_local);
    try std.testing.expectEqualStrings("/explicit/mcp", override);
}

test "defaultIdentityPath uses the state directory" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("HOME", "/home/tester");
    try environ.put("XDG_STATE_HOME", "/xdg/state");

    var buf: [256]u8 = undefined;
    const path = try cli.xdg.defaultIdentityPath(&buf, &environ, .product);
    try std.testing.expectEqualStrings("/xdg/state/glowcap/identity", path);
}

test "end-of-options treats flag-shaped tokens as positionals" {
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
    };
    defer c.deinit();

    // Without `--`, `--nope` is an unknown flag. With `--`, it is a positional.
    const bad = try cli.cmd.dispatch(&fixture_root, &c, &.{ "echo", "--nope" });
    try std.testing.expectEqual(cli.exit_codes.usage, bad);

    const ok = try cli.cmd.dispatch(&dash_root, &c, &.{ "echo", "--", "--nope" });
    try std.testing.expectEqual(cli.exit_codes.ok, ok);
}

test "root -V alias reaches version" {
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
    };
    defer c.deinit();

    const code = try cli.cmd.dispatch(&fixture_root, &c, &.{"-V"});
    try std.testing.expectEqual(cli.exit_codes.ok, code);
}

test "root help footer mentions Examples and XDG_STATE_HOME" {
    var path = [_]*const Command{&fixture_root};
    const text = try cli.cmd_help.writeNodeHelpAlloc(std.testing.allocator, path[0..]);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Examples:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Exit status:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "CapTP waits (product defaults):") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "XDG_STATE_HOME") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "GLOWCAP_STATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[flags] <command>") != null);

    // Help formats from owning constants, prose cannot invent a different map.
    var line: [64]u8 = undefined;
    const timeout_line = try std.fmt.bufPrint(&line, "  {d}  timeout", .{cli.exit_codes.timeout});
    try std.testing.expect(std.mem.indexOf(u8, text, timeout_line) != null);
    const hs_line = try std.fmt.bufPrint(&line, "  handshake  {d} ms", .{cli.ocapn.default_handshake_timeout_ms});
    try std.testing.expect(std.mem.indexOf(u8, text, hs_line) != null);
}
