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

const members = @import("deployment/members.zig");
const nicks = &[_]types.Positional{.{ .name = "nick", .help = "Named bot members", .variadic = true }};
const optional_nicks = &[_]types.Positional{.{ .name = "nick", .help = "Bot members (default: every initialized member)", .required = false, .variadic = true }};
const dir: types.Flag = .{ .long = "dir", .help = "Deployment configuration directory (default $XDG_STATE_HOME/glowcap/rooms-deployment)", .kind = .string_flag };
const image_flag: types.Flag = .{ .long = "image", .help = "Published image tag, digest, or existing local image ID", .kind = .string_flag };
const build_flag: types.Flag = .{ .long = "build", .help = "Build an image from a prepared Linux product directory", .kind = .string_flag };
const rooms: types.Flag = .{ .long = "room", .kind = .string_flag, .repeatable = true, .help = "Existing room to join (repeatable). With no rooms a new bot can receive direct messages and invitations" };
const locator: types.Flag = .{ .long = "locator", .kind = .string_flag, .help = "Directory bootstrap URL or locator. Defaults to the saved home, or http://directory:8080/locator for a new member" };
pub const command: types.Command = .{ .name = "deployment", .short_help = "Run Rooms as a persistent Docker deployment", .children = &.{
    .{ .name = "up", .short_help = "Select an image, start the stack, wait for health, and print capabilities", .flags = &.{ dir, image_flag, build_flag }, .run = run(.up) },
    .{ .name = "bots", .short_help = "Run individually named bot members alongside the deployment", .children = &.{
        .{ .name = "init", .short_help = "Prepare private member files. With --room or --locator also register and issue access before starting agents", .flags = &.{ dir, rooms, locator }, .positionals = nicks, .run = run(.{ .bots = .init }) },
        .{ .name = "session", .short_help = "Run a Rooms session command for one named member", .flags = &.{dir}, .positionals = &.{ .{ .name = "nick", .help = "Bot nickname" }, .{ .name = "command", .help = "Session command and arguments after --", .variadic = true } }, .run = run(.{ .bots = .session }) },
        .{ .name = "inspect", .short_help = "Read one running bot's access, turns and most recent failure as JSON", .flags = &.{dir}, .positionals = &.{.{ .name = "nick", .help = "Bot nickname" }}, .run = run(.{ .bots = .inspect }) },
        .{ .name = "logs", .short_help = "Show recent container output for the named bots and their sessions", .flags = &.{dir}, .positionals = nicks, .run = run(.{ .bots = .logs }) },
        .{ .name = "up", .short_help = "Start these bots and join the named rooms, keeping their existing memberships", .flags = &.{ dir, rooms, locator }, .positionals = nicks, .run = run(.{ .bots = .up }) },
        .{ .name = "status", .short_help = "Inspect the sessions and agents of the named bots", .flags = &.{dir}, .positionals = optional_nicks, .run = run(.{ .bots = .status }) },
        .{ .name = "down", .short_help = "Stop the named bots and their sessions, retaining their identities and state", .flags = &.{dir}, .positionals = nicks, .run = run(.{ .bots = .down }) },
    } },
    .{ .name = "backup-plan", .short_help = "List the selected services and mounts to archive before stopping the deployment", .flags = &.{ dir, .{ .long = "unstarted", .kind = .string_flag, .repeatable = true, .help = "Member whose agent has never started. Require its session store" }, .{ .long = "files-only", .kind = .string_flag, .repeatable = true, .help = "Member prepared only on disk. Its session and agent have never started" } }, .run = run(.backup_plan) },
    .{ .name = "doctor", .short_help = "Inspect configuration and Docker availability without changing them", .flags = &.{dir}, .run = run(.doctor) },
    .{ .name = "status", .short_help = "Show service health and persistent volumes", .flags = &.{dir}, .run = run(.status) },
    .{ .name = "links", .short_help = "Print the page link, operator capabilities, locators, and session links again", .flags = &.{dir}, .run = run(.links) },
    .{ .name = "logs", .short_help = "Follow deployment logs", .flags = &.{dir}, .positionals = &.{.{ .name = "service", .help = "Optional Compose service names", .required = false, .variadic = true }}, .run = run(.logs) },
    .{ .name = "trace", .short_help = "Follow the directory's live protocol trace", .flags = &.{ dir, .{ .long = "json", .help = "Print complete records as JSON lines" } }, .run = run(.trace) },
    .{ .name = "down", .short_help = "Stop the deployment and keep its data", .flags = &.{dir}, .run = run(.down) },
    .{ .name = "restart", .short_help = "Restart the selected deployment and keep its data, identities, and links", .flags = &.{dir}, .run = run(.restart) },
    .{ .name = "reset", .short_help = "Permanently delete the selected data and authority, then restart", .flags = &.{ dir, image_flag, build_flag, .{ .long = "yes", .help = "Confirm the requested destruction without prompting" } }, .positionals = &.{.{ .name = "unit", .help = "session | directory | all" }}, .run = run(.reset) },
} };

const Verb = union(enum) {
    bots: members.Verb,
    backup_plan,
    up,
    doctor,
    status,
    links,
    logs,
    trace,
    down,
    restart,
    reset,

    /// Whether the verb chooses an image and brings the services up.
    fn starts(verb: Verb) bool {
        return switch (verb) {
            .up, .reset => true,
            .backup_plan, .doctor, .status, .links, .logs, .trace, .down, .restart, .bots => false,
        };
    }
    /// A member owns its own writer lock. Reading the selected base under a
    /// shared lease keeps a base reset or image change out of its rollout.
    fn lock(verb: Verb) Io.File.Lock {
        return switch (verb) {
            .up, .down, .restart, .reset => .exclusive,
            .bots => |member| if (member.mutating()) .shared else .none,
            else => .none,
        };
    }
};

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
    // Compose names the services, including any the override adds, and refuses
    // an unknown one itself. An operand that starts with a dash would be a
    // Compose option, so it is refused here.
    if (verb == .logs) {
        for (parsed.positionals) |service| {
            if (service.len == 0 or service[0] == '-') return error.Usage;
        }
    }
    const cwd = try std.process.currentPathAlloc(ctx.io, gpa);
    const workspace = parsed.flagString("dir") orelse blk: {
        const base = nonempty(ctx.environ.get("XDG_STATE_HOME")) orelse try std.Io.Dir.path.join(gpa, &.{
            nonempty(ctx.environ.get("HOME")) orelse return error.Usage, ".local/state",
        });
        break :blk try std.Io.Dir.path.join(gpa, &.{ base, "glowcap/rooms-deployment" });
    };
    const absolute_dir = try std.Io.Dir.path.resolve(gpa, &.{ cwd, workspace });
    const absolute_build = if (build.len == 0) "" else try std.Io.Dir.path.resolve(gpa, &.{ cwd, build });
    if (build.len != 0) _ = try config.linuxPlatform(ctx.io, gpa, absolute_build);
    const starts = comptime verb.starts();
    const source_checkout = if (starts and image.len == 0 and build.len == 0 and @import("builtin").target.os.tag == .linux) checkout else null;
    // Source selection and validation belong here. The checkout launcher owns
    // its toolchain and refreshes the executable before any Docker effect.
    if (source_checkout) |root| try prepareCheckout(ctx, parsed, gpa, root);
    const prefix = try installation.prefix(ctx);
    defer ctx.gpa.free(prefix);
    const templates = try std.Io.Dir.path.join(gpa, &.{ prefix, "share/glowcap/deployment" });
    var environ = try ctx.environ.clone(gpa);
    try environ.put("COMPOSE_DISABLE_ENV_FILE", "1");
    const docker: Docker = .{ .io = ctx.io, .gpa = gpa, .environ = &environ, .workspace = absolute_dir };

    if (verb == .doctor) {
        try stdout(ctx.io, try gpa.print("configuration: {s}\n", .{absolute_dir}));
        if (Io.Dir.cwd().openDir(ctx.io, absolute_dir, .{})) |directory| {
            defer directory.close(ctx.io);
            const state: config.Config = .{ .io = ctx.io, .gpa = gpa, .dir = directory, .path = absolute_dir, .templates = templates };
            if (try state.image()) |selected| {
                try stdout(ctx.io, try gpa.print("selected image: {s}\n", .{selected}));
            } else {
                try stdout(ctx.io, "selected image: none (run deployment up to select an image)\n");
            }
        } else |err| switch (err) {
            error.FileNotFound => try stdout(ctx.io, "configuration directory: missing (run deployment up to initialize)\n"),
            else => return err,
        }
    }

    // Named commands call Docker only for the operation they perform. File-only
    // initialization can run offline and status needs one daemon snapshot.
    if (comptime verb != .bots) try checkDocker(docker, verb == .doctor);
    if (verb == .doctor) return;
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
    const mode = comptime verb.lock();
    const state_lock = @import("../../operability/state_lock.zig");
    var lock: ?state_lock.Guard = switch (mode) {
        .none => null,
        .shared => try state_lock.tryAcquireShared(ctx.io, absolute_dir),
        .exclusive => try state_lock.tryAcquire(ctx.io, absolute_dir),
    };
    defer if (lock) |*guard| guard.deinit();
    if (starts) {
        try state.prepare();
        // Up and reset choose an image by one rule, before any service stops:
        // an explicit --image or --build, else a Linux checkout's prepared
        // product, else (installed) the saved selection or the release image.
        const source = if (source_checkout) |root|
            try std.Io.Dir.path.join(gpa, &.{ root, "zig-out/product" })
        else
            absolute_build;
        const default_image = try gpa.print("ghcr.io/glowcap-org/glowcap-rooms:v{d}.{d}.{d}", .{
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
    if (comptime verb == .bots) return members.perform(state, docker, parsed, verb.bots);
    if (comptime verb == .backup_plan) return @import("deployment/backup.zig").plan(state, docker, parsed);
    // Preflight includes the operator override before any stop or deletion.
    _ = try docker.query(try docker.composeArgs(&.{ "config", "--quiet" }));
    switch (verb) {
        .up => try operations.up(docker),
        .links => try operations.links(docker),
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
        .backup_plan, .bots, .doctor => unreachable, // answered above, before any configuration exists
    }
}

fn checkDocker(docker: Docker, show_versions: bool) !void {
    versionProbe(docker, if (show_versions) &.{"version"} else &.{ "version", "--format", "{{.Server.Version}}" }, show_versions) catch |err| {
        if (err == error.FileNotFound) {
            log.err(docker.io, "Docker was not found on PATH. Install Docker with Compose, then rerun this command.", .{});
        } else {
            log.err(docker.io, "Check that the Docker daemon is running and that your user can reach it with `docker version`.", .{});
        }
        return err;
    };
    versionProbe(docker, &.{ "compose", "version" }, show_versions) catch |err| {
        log.err(docker.io, "Check that Docker Compose is installed with `docker compose version`.", .{});
        return err;
    };
}

fn versionProbe(docker: Docker, operands: []const []const u8, show: bool) !void {
    if (show) try docker.run(operands, 15) else _ = try docker.query(operands);
}

fn prepareCheckout(ctx: *Ctx, parsed: *types.Parsed, gpa: std.mem.Allocator, root: []const u8) !void {
    // REPL and installed operations keep their prepared executable. A marker
    // from the launcher acknowledges preparation for this one argv dispatch.
    if (ctx.front != .argv) return;
    if (std.mem.eql(u8, ctx.environ.get("GLOWCAP_CHECKOUT_PREPARED") orelse "", root)) return;
    var environ = try ctx.environ.clone(gpa);
    try environ.put("GLOWCAP_PREPARE_CHECKOUT", root);
    const launcher = try std.Io.Dir.path.join(gpa, &.{ root, "glowcap" });
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
