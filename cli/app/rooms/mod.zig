//! Product command composition. Zig owns argv/help/completion and installation
//! paths; Rust owns service configuration, supervision, and Rooms behavior.
const std = @import("std");
const Ctx = @import("../../ctx.zig").Ctx;
const Parsed = @import("../../cmd/types.zig").Parsed;
const runtime = @import("../../operability/installation.zig");
const log = @import("../../operability/log.zig");
pub const commands = @import("commands.zig").commands;

pub const Mode = enum { service, serve, session_serve, session_ready, capabilities, status, locator, revision, skills };

fn env(ctx: *Ctx, key: []const u8) ?[]const u8 {
    const value = ctx.environ.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

pub fn run(comptime name: []const u8, comptime mode: Mode) *const fn (*Ctx, *Parsed) anyerror!u8 {
    return struct {
        fn execute(ctx: *Ctx, parsed: *Parsed) anyerror!u8 {
            var arena = std.heap.ArenaAllocator.init(ctx.gpa);
            defer arena.deinit();
            const alloc = arena.allocator();
            const root = try runtime.prefix(ctx);
            defer ctx.gpa.free(root);
            if (mode == .skills) {
                const path = try std.fs.path.join(alloc, &.{ root, "share/glowcap/skills" });
                if (!runtime.exists(ctx, path)) {
                    log.err(ctx.io, "missing installed skills; install the complete glowcap package", .{});
                    return 1;
                }
                try @import("../../argv.zig").writeStdout(ctx.io, try std.fmt.allocPrint(alloc, "{s}\n", .{path}));
                return 0;
            }
            var arguments: std.ArrayList([]const u8) = .empty;
            if (mode == .serve) {
                // Product composition owns the child executable. The private
                // web front's test override must not select another release.
                const server = try runtime.executable(ctx, "rooms-server");
                defer ctx.gpa.free(server);
                try arguments.append(alloc, try std.fmt.allocPrint(alloc, "--server={s}", .{server}));
                const assets = parsed.flagString("assets") orelse try std.fs.path.join(alloc, &.{ root, "share/glowcap/rooms" });
                if (!runtime.exists(ctx, assets)) {
                    log.err(ctx.io, "missing prepared browser assets at {s}; install the complete glowcap package (contributors: zig build rooms-build)", .{assets});
                    return 1;
                }
                try arguments.appendSlice(alloc, &.{ "--prepared", try std.fmt.allocPrint(alloc, "--assets={s}", .{assets}) });
                // HTTP is loopback by default. CapTP retains the server's
                // separate authenticated discovery and operator-grant policy.
                if (parsed.flagString("http-bind") == null) try arguments.append(alloc, "--http-bind=127.0.0.1");
                if (parsed.flagString("state") == null and env(ctx, "GLOWCAP_ROOMS_STATE") == null) {
                    if (env(ctx, "HOME") == null and env(ctx, "XDG_STATE_HOME") == null and env(ctx, "GLOWCAP_STATE") == null) {
                        log.err(ctx.io, "name durable Rooms storage with --state when no user state directory is configured", .{});
                        return error.Usage;
                    }
                    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const state = try @import("../../operability/xdg.zig").defaultStateDir(&state_buf, ctx.environ, .product);
                    try arguments.append(alloc, try std.fmt.allocPrint(alloc, "--state={s}/rooms", .{state}));
                }
            }
            if (mode == .session_ready) {
                const file = parsed.flagString("file") orelse return error.Usage;
                try arguments.append(alloc, try std.fmt.allocPrint(alloc, "--check-ready={s}", .{file}));
            } else if (mode == .status or mode == .locator or mode == .revision) {
                const option = switch (mode) {
                    .status => "check-ready",
                    .locator => "locator",
                    .revision => "ui-version",
                    else => unreachable,
                };
                try arguments.append(alloc, if (parsed.flagString("url")) |url| try std.fmt.allocPrint(alloc, "--{s}={s}", .{ option, url }) else try std.fmt.allocPrint(alloc, "--{s}", .{option}));
            } else if (mode == .capabilities) {
                try arguments.append(alloc, if (parsed.flagString("state")) |state| try std.fmt.allocPrint(alloc, "--capabilities={s}", .{state}) else "--capabilities");
            } else {
                if (mode == .session_serve) {
                    if (parsed.flagString("dir") == null) {
                        log.err(ctx.io, "--dir is required for foreground session storage", .{});
                        return error.Usage;
                    }
                    try arguments.append(alloc, "--local-control");
                }
                var flags = parsed.flags.iterator();
                while (flags.next()) |entry| {
                    const key = entry.key_ptr.*;
                    if (mode == .serve and std.mem.eql(u8, key, "assets")) continue;
                    const value = switch (entry.value_ptr.*) {
                        .string_flag => |text| text,
                        .bool_flag => |yes| if (yes) "true" else "false",
                    };
                    const option = if (mode == .session_serve and std.mem.eql(u8, key, "dir")) "state" else key;
                    try arguments.append(alloc, try std.fmt.allocPrint(alloc, "--{s}={s}", .{ option, value }));
                }
                try arguments.appendSlice(alloc, parsed.positionals);
            }
            return runtime.replace(ctx, name, arguments.items);
        }
    }.execute;
}
