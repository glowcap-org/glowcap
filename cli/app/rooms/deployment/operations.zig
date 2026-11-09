//! Select an immutable product image, supervise Compose, and hand authority
//! back to its operator. No deployment operation builds application source.
const std = @import("std");
const Io = std.Io;
const Config = @import("config.zig").Config;
const config = @import("config.zig");
const Docker = @import("docker.zig").Client;
const volumes_config = @import("volumes.zig");
const log = @import("../../../operability/log.zig");
const stdout = @import("../../../argv.zig").writeStdout;

pub fn selectImage(state: Config, docker: Docker, image: []const u8, build: []const u8, default_image: []const u8) !void {
    if (build.len != 0) {
        var random: [16]u8 = undefined;
        try state.io.randomSecure(&random);
        const name = try std.fmt.allocPrint(state.gpa, ".image-build-{s}", .{std.fmt.bytesToHex(random, .lower)});
        try state.dir.createDir(state.io, name, .fromMode(0o700));
        defer state.dir.deleteTree(state.io, name) catch |err| {
            log.err(state.io, "could not remove temporary image build {s}/{s}: {s}", .{ state.path, name, @errorName(err) });
        };
        const temporary = try state.dir.openDir(state.io, name, .{});
        defer temporary.close(state.io);
        try temporary.createDir(state.io, "product", .fromMode(0o755));
        const output = try temporary.openDir(state.io, "product", .{});
        defer output.close(state.io);
        try @import("../../../installation/mod.zig").snapshot(state.io, state.gpa, build, output);
        const context = try std.fs.path.join(state.gpa, &.{ state.path, name, "product" });
        const release = try config.productRelease(state.io, state.gpa, context);
        const dockerfile = try std.fs.path.join(state.gpa, &.{ context, "share/glowcap/deployment/rooms.Dockerfile" });
        const result = try std.fs.path.join(state.gpa, &.{ state.path, name, "image" });
        const label = try std.fmt.allocPrint(state.gpa, "{s}={s}", .{ config.revision_label, release.revision orelse "unrecorded" });
        try docker.run(&.{ "build", "--platform", release.platform, "--label", label, "--file", dockerfile, "--iidfile", result, context }, 1800);
        const id = std.mem.trim(u8, try temporary.readFileAlloc(state.io, "image", state.gpa, .limited(128)), " \r\n\t");
        try state.select(id);
        log.writeMsg(state.io, try std.fmt.allocPrint(state.gpa, "Built and selected image {s} from {s} at revision {s}.\n", .{
            short(id), build, release.revision orelse "unrecorded",
        }));
    } else {
        if (image.len == 0 and try state.image() != null) return announceKept(state, docker);
        const requested = if (image.len == 0) default_image else image;
        const present = try docker.capture(&.{ "image", "inspect", requested });
        if (!present.term.success()) {
            docker.run(&.{ "pull", requested }, 1800) catch |err| {
                log.err(state.io, "could not obtain image {s}. Select a published --image or use --build with a prepared Linux product", .{requested});
                return err;
            };
        }
        const id = try docker.query(&.{ "image", "inspect", "--format", "{{.Id}}", requested });
        try state.select(id);
        log.writeMsg(state.io, try std.fmt.allocPrint(state.gpa, "Selected image {s} ({s}) at revision {s}.\n", .{
            short(id), requested, try imageRevision(docker, id),
        }));
    }
}

/// An `up` or `reset` that keeps the selected image says so, with the revision
/// that image was built from: an operator who rebuilt the product and ran
/// reset otherwise sees fresh data on old code and no reason why.
pub fn announceKept(state: Config, docker: Docker) !void {
    const id = try state.image() orelse return;
    log.writeMsg(state.io, try std.fmt.allocPrint(state.gpa, "Keeping the selected image {s} at revision {s}. Pass --build <product> or --image <reference> to deploy another.\n", .{
        short(id), try imageRevision(docker, id),
    }));
}

/// The revision an image recorded when it was built from a product, or
/// `unrecorded` for an image that carries no revision label.
fn imageRevision(docker: Docker, id: []const u8) ![]const u8 {
    const format = "{{index .Config.Labels \"" ++ config.revision_label ++ "\"}}";
    const value = docker.query(&.{ "image", "inspect", "--format", format, id }) catch return "unrecorded";
    return if (value.len == 0 or std.mem.eql(u8, value, "<no value>")) "unrecorded" else value;
}

/// An image ID as an operator compares two of them: the digest's first twelve.
fn short(id: []const u8) []const u8 {
    return if (config.imageId(id)) id[0 .. "sha256:".len + 12] else id;
}

pub fn up(docker: Docker) !void {
    const networks = try docker.query(&.{ "network", "ls", "--format", "{{.Name}}" });
    if (!config.containsLine(networks, "glowcap-rooms-net")) try docker.run(&.{ "network", "create", "glowcap-rooms-net" }, 30);
    docker.run(try docker.composeArgs(&.{ "up", "-d", "--wait", "--wait-timeout", "210" }), 240) catch |err| {
        log.err(docker.io, "deployment did not become healthy. Inspect `glowcap apps rooms deployment logs` using the same --dir", .{});
        return err;
    };
    try links(docker);
}

/// Print what the running deployment hands out, as `up` prints it: the page
/// link, the operator capabilities, the directory locator, the browser
/// revision, the shared session's links, and the trace link. Every answer is
/// read from the running services, so nothing starts or restarts.
pub fn links(docker: Docker) !void {
    const page = rooms(docker, "directory", &.{}, &.{"page"}) catch |err| {
        log.err(docker.io, "could not read the running deployment ({s}). Start it with `glowcap apps rooms deployment up`, or inspect `deployment status` and `deployment logs` using the same --dir", .{@errorName(err)});
        return err;
    };
    const locator = try rooms(docker, "directory", &.{}, &.{"locator"});
    const revision = try rooms(docker, "directory", &.{}, &.{"revision"});
    const session = try rooms(docker, "session", &.{}, &.{ "session", "ready", "--file=/run/rooms-session/use.sturdyref" });
    const management = try rooms(docker, "session", &.{}, &.{ "session", "ready", "--file=/session-state/management.sturdyref" });
    const trace = try rooms(docker, "directory", &.{}, &.{ "trace", "--state=/state", "--print-link" });
    // The capabilities print as complete recipes with the locators the running
    // directory advertises, which the container's own command reads from it.
    const capabilities = try rooms(docker, "directory", &.{}, &.{ "directory", "capabilities" });
    // The page link leads, because opening it is what a person does next. A
    // deployment that allows no page prints none.
    if (page.len != 0) try stdout(docker.io, try std.fmt.allocPrint(docker.gpa, "\nOpen the page:\n{s}\n", .{page}));
    try stdout(docker.io, try std.fmt.allocPrint(docker.gpa, "\nDirectory operator capabilities:\n{s}\n\nDirectory locator:\n{s}\n\nBrowser revision:\n{s}\n\nShared session capability:\n{s}\n\nShared session management capability:\n{s}\n", .{ capabilities, locator, revision, session, management }));
    if (trace.len != 0) try stdout(docker.io, try std.fmt.allocPrint(docker.gpa, "\nROOMS-TRACE-LISTENING {s}\nFollow protocol events: glowcap apps rooms deployment trace\n", .{trace}));
}

/// Ask a running service's own `glowcap apps rooms` for an answer, with any
/// `exec` options (such as `-e NAME=value`) before the service.
fn rooms(docker: Docker, service: []const u8, options: []const []const u8, operands: []const []const u8) ![]const u8 {
    const command: []const []const u8 = &.{ service, "/runtime/bin/glowcap", "apps", "rooms" };
    return docker.query(try docker.composeArgs(try std.mem.concat(docker.gpa, []const u8, &.{ &.{ "exec", "-T" }, options, command, operands })));
}

pub const Unit = enum {
    session,
    directory,
    all,

    fn description(self: Unit) []const u8 {
        return switch (self) {
            .session => "the shared session, its identity, and all session access links",
            .directory => "the directory identity, grants, issued room links, and kept public-room history",
            .all => "all Rooms data, identities, grants, and access links",
        };
    }
};

pub fn reset(docker: Docker, unit: Unit, confirmed: bool) !void {
    const selected = try volumes_config.Selected.load(docker);
    defer selected.deinit();
    var targets: [2][]const u8 = undefined;
    var count: usize = 0;
    for ([_]Unit{ .session, .directory }) |candidate| {
        if (unit != .all and unit != candidate) continue;
        const kind = std.meta.stringToEnum(volumes_config.Kind, @tagName(candidate)).?;
        const target = try selected.name(kind, true);
        for (targets[0..count]) |previous| {
            if (std.mem.eql(u8, previous, target)) return error.AmbiguousDeploymentVolume;
        }
        targets[count] = target;
        count += 1;
    }
    const volumes = try docker.query(&.{ "volume", "ls", "--quiet" });
    if (unit != .all and !config.containsLine(volumes, targets[0])) return error.MissingDeploymentVolume;
    log.writeMsg(docker.io, try std.fmt.allocPrint(docker.gpa, "Reset {s} permanently removes {s}. To restart while keeping data and links, use `deployment restart`.\n", .{ @tagName(unit), unit.description() }));
    if (!confirmed and !try confirmReset(docker, unit)) {
        log.writeMsg(docker.io, "Reset cancelled. No services or volumes were changed.\n");
        return;
    }
    try docker.run(try docker.composeArgs(&.{"down"}), 120);
    // The override may declare other volumes. Even `all` only removes the
    // two named units (session and state), never every volume Compose can name.
    for (targets[0..count]) |target| {
        if (config.containsLine(volumes, target)) {
            docker.run(&.{ "volume", "rm", target }, 60) catch |err| {
                log.err(docker.io, "reset could not remove {s}. The stack remains stopped and earlier selected volumes may already have been removed. Inspect the data before running deployment up", .{target});
                return err;
            };
        }
    }
    try up(docker);
}

fn confirmReset(docker: Docker, unit: Unit) !bool {
    const tty = Io.Dir.cwd().openFile(docker.io, "/dev/tty", .{}) catch |err| {
        log.err(docker.io, "reset needs an interactive terminal ({s}). Use --yes only to confirm destruction without prompting", .{@errorName(err)});
        return error.ConfirmationRequired;
    };
    defer tty.close(docker.io);
    var buffer: [64]u8 = undefined;
    var reader = tty.readerStreaming(docker.io, &buffer);
    const prompt = try std.fmt.allocPrint(docker.gpa, "Proceed with reset {s}? Type yes to confirm, or no to cancel [no]: ", .{@tagName(unit)});
    while (true) {
        log.writeMsg(docker.io, prompt);
        var line: [16]u8 = undefined;
        var len: usize = 0;
        var overlong = false;
        // Consume the entire line with bounded storage. An oversized answer's
        // suffix must never become a second answer that confirms destruction.
        while (true) {
            const byte = reader.interface.takeByte() catch |err| switch (err) {
                error.EndOfStream => return false,
                else => return err,
            };
            if (byte == '\n') break;
            if (len < line.len) {
                line[len] = byte;
                len += 1;
            } else overlong = true;
        }
        if (!overlong) {
            const answer = std.mem.trim(u8, line[0..len], " \r\t");
            if (std.mem.eql(u8, answer, "yes")) return true;
            if (answer.len == 0 or std.ascii.eqlIgnoreCase(answer, "no") or std.ascii.eqlIgnoreCase(answer, "n")) return false;
        }
        log.writeMsg(docker.io, "Please type the full word yes to reset, or no to cancel.\n");
    }
}
