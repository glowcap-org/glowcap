//! Rooms deployment commands select immutable images and supervise Docker.
//! The host owns Docker. The running image contains only product dependencies.
const std = @import("std");
const types = @import("../../cmd/types.zig");
const Ctx = @import("../../ctx.zig").Ctx;
const installation = @import("../../operability/installation.zig");
const log = @import("../../operability/log.zig");
const version = @import("build_options");
const config = @import("deployment/config.zig");
const operations = @import("deployment/operations.zig");
const Docker = @import("deployment/docker.zig").Client;
const Io = std.Io;
const stdout = @import("../../argv.zig").writeStdout;

const dir: types.Flag = .{ .long = "dir", .help = "Deployment configuration directory (default $XDG_STATE_HOME/glowcap/rooms-deployment)", .kind = .string_flag };
const image_flag: types.Flag = .{ .long = "image", .help = "Published image tag, digest, or existing local image ID", .kind = .string_flag };
const build_flag: types.Flag = .{ .long = "build", .help = "Build an image from a prepared Linux product directory", .kind = .string_flag };
pub const command: types.Command = .{ .name = "deployment", .short_help = "Run Rooms as a persistent Docker deployment", .children = &.{
    .{ .name = "up", .short_help = "Select an image, start the stack, wait for health, and print capabilities", .flags = &.{ dir, image_flag, build_flag }, .run = run(.up) },
    .{ .name = "doctor", .short_help = "Inspect configuration and Docker availability without changing them", .flags = &.{dir}, .run = run(.doctor) },
    .{ .name = "status", .short_help = "Show service health and persistent volumes", .flags = &.{dir}, .run = run(.status) },
    .{ .name = "logs", .short_help = "Follow deployment logs", .flags = &.{dir}, .positionals = &.{.{ .name = "service", .help = "Optional Compose service names", .required = false, .variadic = true }}, .run = run(.logs) },
    .{ .name = "trace", .short_help = "Follow the directory's live protocol trace", .flags = &.{ dir, .{ .long = "json", .help = "Print complete records as JSON lines" } }, .run = run(.trace) },
    .{ .name = "down", .short_help = "Stop the deployment and keep its data", .flags = &.{dir}, .run = run(.down) },
    .{ .name = "restart", .short_help = "Restart the selected deployment and keep its data, identities, and links", .flags = &.{dir}, .run = run(.restart) },
    .{ .name = "reset", .short_help = "Permanently delete the selected data and authority, then restart", .flags = &.{ dir, image_flag, build_flag, .{ .long = "yes", .help = "Confirm the requested destruction without prompting" } }, .positionals = &.{.{ .name = "unit", .help = "session | state | all" }}, .run = run(.reset) },
} };

const Verb = enum { up, doctor, status, logs, trace, down, restart, reset };

fn run(comptime verb: Verb) *const fn (*Ctx, *types.Parsed) anyerror!u8 {
    return struct {
        fn execute(ctx: *Ctx, parsed: *types.Parsed) anyerror!u8 {
            @import("../../operability/signals.zig").interruptible(void, ctx.io, work, .{ ctx, parsed }) catch |err| {
                log.err(ctx.io, "deployment {s} failed: {s}", .{ @tagName(verb), @errorName(err) });
                return 1;
            };
            return 0;
        }

        fn work(ctx: *Ctx, parsed: *types.Parsed) anyerror!void {
            try perform(ctx, parsed, verb);
        }
    }.execute;
}

fn perform(ctx: *Ctx, parsed: *types.Parsed, comptime verb: Verb) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();
    for ([_][]const u8{ "image", "build", "dir" }) |flag| {
        if (parsed.flagString(flag)) |value| if (value.len == 0) return error.Usage;
    }
    const image = parsed.flagString("image") orelse "";
    const checkout = nonempty(ctx.environ.get("GLOWCAP_CHECKOUT_ROOT"));
    const build = parsed.flagString("build") orelse "";
    if (image.len != 0 and build.len != 0) {
        log.err(ctx.io, "--image and --build are alternative image sources", .{});
        return error.Usage;
    }
    if (image.len != 0 and image[0] == '-') return error.Usage;
    const unit = if (verb == .reset)
        std.meta.stringToEnum(operations.Unit, parsed.positionals[0]) orelse return error.Usage
    else
        operations.Unit.all;
    if (verb == .logs) {
        for (parsed.positionals) |service| {
            if (!std.mem.eql(u8, service, "directory") and !std.mem.eql(u8, service, "session")) return error.Usage;
        }
    }
    const cwd = try std.process.currentPathAlloc(ctx.io, gpa);
    const workspace = parsed.flagString("dir") orelse blk: {
        const base = nonempty(ctx.environ.get("XDG_STATE_HOME")) orelse try std.fs.path.join(gpa, &.{
            nonempty(ctx.environ.get("HOME")) orelse return error.Usage, ".local/state",
        });
        break :blk try std.fs.path.join(gpa, &.{ base, "glowcap/rooms-deployment" });
    };
    const absolute_dir = try std.fs.path.resolve(gpa, &.{ cwd, workspace });
    const absolute_build = if (build.len == 0) "" else try std.fs.path.resolve(gpa, &.{ cwd, build });
    if (build.len != 0) _ = try config.linuxPlatform(ctx.io, gpa, absolute_build);
    const starts = verb == .up or verb == .reset;
    const source_checkout = if (starts and image.len == 0 and build.len == 0 and @import("builtin").os.tag == .linux) checkout else null;
    // Source selection and validation belong here. The checkout launcher owns
    // its toolchain and refreshes the executable before any Docker effect.
    if (source_checkout) |root| try prepareCheckout(ctx, parsed, gpa, root);
    const prefix = try installation.prefix(ctx);
    defer ctx.gpa.free(prefix);
    const templates = try std.fs.path.join(gpa, &.{ prefix, "share/glowcap/deployment" });
    var environ = try ctx.environ.clone(gpa);
    try environ.put("COMPOSE_DISABLE_ENV_FILE", "1");
    const docker: Docker = .{ .io = ctx.io, .gpa = gpa, .environ = &environ, .workspace = absolute_dir };

    if (verb == .doctor) {
        try stdout(ctx.io, try std.fmt.allocPrint(gpa, "configuration: {s}\n", .{absolute_dir}));
        if (Io.Dir.cwd().openDir(ctx.io, absolute_dir, .{})) |directory| {
            defer directory.close(ctx.io);
            const state: config.Config = .{ .io = ctx.io, .gpa = gpa, .dir = directory, .path = absolute_dir, .templates = templates };
            if (try state.image()) |selected| {
                try stdout(ctx.io, try std.fmt.allocPrint(gpa, "selected image: {s}\n", .{selected}));
            } else {
                try stdout(ctx.io, "selected image: none (run deployment up to select an image)\n");
            }
        } else |err| switch (err) {
            error.FileNotFound => try stdout(ctx.io, "configuration directory: missing (run deployment up to initialize)\n"),
            else => return err,
        }
        try docker.run(&.{"version"}, 15);
        try docker.run(&.{ "compose", "version" }, 15);
        return;
    }

    _ = docker.query(&.{ "version", "--format", "{{.Server.Version}}" }) catch |err| {
        log.err(ctx.io, "Docker with Compose and a reachable daemon are required on this host", .{});
        return err;
    };
    _ = try docker.query(&.{ "compose", "version" });
    const directory = if (starts)
        try Io.Dir.cwd().createDirPathOpen(ctx.io, absolute_dir, .{ .permissions = .fromMode(0o700) })
    else
        Io.Dir.cwd().openDir(ctx.io, absolute_dir, .{}) catch |err| {
            if (err == error.FileNotFound) {
                notConfigured(ctx.io, absolute_dir, "configuration directory is missing");
                return error.DeploymentNotConfigured;
            }
            log.err(ctx.io, "cannot open deployment configuration {s}: {s}", .{ absolute_dir, @errorName(err) });
            return err;
        };
    defer directory.close(ctx.io);
    const state: config.Config = .{ .io = ctx.io, .gpa = gpa, .dir = directory, .path = absolute_dir, .templates = templates };
    const mutating = verb == .up or verb == .down or verb == .restart or verb == .reset;
    const state_lock = @import("../../operability/state_lock.zig");
    var lock: ?state_lock.Guard = if (mutating) try state_lock.tryAcquire(ctx.io, absolute_dir) else null;
    defer if (lock) |*guard| guard.deinit();
    if (starts) {
        try state.prepare();
        // Up and reset choose an image by one rule, before any service stops:
        // an explicit --image or --build, else a Linux checkout's prepared
        // product, else (installed) the saved selection or the release image.
        const source = if (source_checkout) |root|
            try std.fs.path.join(gpa, &.{ root, "zig-out/product" })
        else
            absolute_build;
        const default_image = try std.fmt.allocPrint(gpa, "ghcr.io/jimisaacs/glowcap-rooms:v{d}.{d}.{d}", .{
            version.version_major, version.version_minor, version.version_patch,
        });
        log.writeMsg(ctx.io, "Preparing deployment image and configuration. Services and volumes have not been changed.\n");
        try operations.selectImage(state, docker, image, source, default_image);
    }
    const selected = try state.image() orelse {
        notConfigured(ctx.io, absolute_dir, "no selected image (the image file is missing)");
        return error.DeploymentNotConfigured;
    };
    try environ.put("GLOWCAP_ROOMS_IMAGE", selected);
    // Preflight includes the operator override before any stop or deletion.
    _ = try docker.query(try docker.composeArgs(&.{ "config", "--quiet" }));
    switch (verb) {
        .up => try operations.up(docker),
        .status => {
            try docker.run(try docker.composeArgs(&.{"ps"}), 15);
            try docker.run(&.{ "volume", "ls", "--filter", "name=glowcap-rooms-" }, 15);
        },
        .down => try docker.run(try docker.composeArgs(&.{"down"}), 120),
        .restart => {
            try docker.run(try docker.composeArgs(&.{ "restart", "--timeout", "60" }), 240);
            try operations.up(docker);
        },
        .logs => {
            const operands = try std.mem.concat(gpa, []const u8, &.{ &.{ "logs", "-f" }, parsed.positionals });
            // Continuous logs are intentionally supervised by the calling terminal.
            return std.process.replace(ctx.io, .{ .argv = try docker.args(try docker.composeArgs(operands)), .environ_map = &environ });
        },
        .trace => {
            // A disposable viewer shares the deployment network and private
            // state. Compose retires it on interruption; exec only detaches
            // the Docker client and leaves the remote viewer running.
            const base: []const []const u8 = &.{ "run", "--rm", "--no-deps", "-T", "--entrypoint", "/runtime/bin/glowcap", "directory", "apps", "rooms", "trace", "--state=/state", "--url=http://directory:8080" };
            const operands = try std.mem.concat(gpa, []const u8, &.{ base, if (parsed.flagBool("json")) &.{"--json"} else &.{} });
            return std.process.replace(ctx.io, .{ .argv = try docker.args(try docker.composeArgs(operands)), .environ_map = &environ });
        },
        .reset => try operations.reset(docker, unit, parsed.flagBool("yes")),
        .doctor => unreachable, // answered above, before any configuration exists
    }
}

fn prepareCheckout(ctx: *Ctx, parsed: *types.Parsed, gpa: std.mem.Allocator, root: []const u8) !void {
    // REPL and installed operations keep their prepared executable. A marker
    // from the launcher acknowledges preparation for this one argv dispatch.
    if (ctx.front != .argv) return;
    if (std.mem.eql(u8, ctx.environ.get("GLOWCAP_CHECKOUT_PREPARED") orelse "", root)) return;
    var environ = try ctx.environ.clone(gpa);
    try environ.put("GLOWCAP_PREPARE_CHECKOUT", root);
    const launcher = try std.fs.path.join(gpa, &.{ root, "glowcap" });
    const arguments = try std.mem.concat(gpa, []const u8, &.{ &.{launcher}, parsed.argv });
    return std.process.replace(ctx.io, .{ .argv = arguments, .environ_map = &environ });
}

fn notConfigured(io: Io, path: []const u8, reason: []const u8) void {
    log.err(io, "deployment is not configured at {s}: {s}", .{ path, reason });
    log.writeMsg(io, "Select the existing configuration with --dir, or copy its operator override into this directory. Then run `glowcap apps rooms deployment up` to select an image.\n");
}

fn nonempty(value: ?[]const u8) ?[]const u8 {
    return if (value) |v| if (v.len == 0) null else v else null;
}
