//! Thin `rooms-peer` install alias: forward to `pancake app rooms-peer …`
//! (ADR-0084).
//!
//! No CapTP / iroh link — only path resolution and process forward/replace.
const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

/// Resolve the product binary next to this shim, else on PATH. Test-visible.
pub fn resolvePancakePath(io: Io, gpa: std.mem.Allocator, path_env: ?[]const u8) ![:0]u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(io, &dir_buf)) |dir_len| {
        const sibling = try std.fmt.allocPrintSentinel(gpa, "{s}/pancake", .{dir_buf[0..dir_len]}, 0);
        if (Io.Dir.cwd().access(io, sibling, .{ .execute = true })) |_| {
            return sibling;
        } else |_| {
            gpa.free(sibling);
        }
    } else |_| {}

    if (path_env) |path| {
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = try std.fmt.allocPrintSentinel(gpa, "{s}/pancake", .{dir}, 0);
            if (Io.Dir.cwd().access(io, candidate, .{ .execute = true })) |_| {
                return candidate;
            } else |_| {
                gpa.free(candidate);
            }
        }
    }
    return error.PancakeNotFound;
}

fn termExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        .signal, .stopped => 128,
        .unknown => 1,
    };
}

fn errLine(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "rooms-peer: " ++ fmt ++ "\n", args) catch return;
    Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pancake = resolvePancakePath(init.io, arena, init.environ_map.get("PATH")) catch {
        errLine(init.io, "could not find `pancake` beside this binary or on PATH; install both from `zig build`", .{});
        std.process.exit(1);
    };

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // rooms-peer

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, pancake);
    try argv.append(arena, "app");
    try argv.append(arena, "rooms-peer");
    while (args.next()) |a| try argv.append(arena, a);

    // Prefer process replacement so signals and PID match `pancake app rooms-peer`.
    if (builtin.os.tag == .linux and builtin.link_libc) {
        var z_argv: std.ArrayList(?[*:0]const u8) = .empty;
        try z_argv.append(arena, pancake.ptr);
        try z_argv.append(arena, "app");
        try z_argv.append(arena, "rooms-peer");
        var rest = std.process.Args.Iterator.init(init.minimal.args);
        _ = rest.next();
        while (rest.next()) |a| {
            try z_argv.append(arena, (try arena.dupeSentinel(u8, a, 0)).ptr);
        }
        try z_argv.append(arena, null);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        _ = std.posix.system.execve(pancake.ptr, @ptrCast(z_argv.items.ptr), envp);
        // Fall through to spawn if execve failed.
    }

    var child = std.process.spawn(init.io, .{
        .argv = argv.items,
        .environ_map = init.environ_map,
    }) catch |err| {
        errLine(init.io, "failed to run {s}: {s}", .{ pancake, @errorName(err) });
        std.process.exit(1);
    };
    const term = try child.wait(init.io);
    std.process.exit(termExitCode(term));
}
