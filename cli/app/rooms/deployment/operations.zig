//! Select an immutable product image, supervise Compose, and hand authority
//! back to its operator. No deployment operation builds application source.
const std = @import("std");
const Io = std.Io;
const Config = @import("config.zig").Config;
const config = @import("config.zig");
const Docker = @import("docker.zig").Client;
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
        const platform = try config.linuxPlatform(state.io, state.gpa, context);
        const dockerfile = try std.fs.path.join(state.gpa, &.{ context, "share/glowcap/deployment/rooms.Dockerfile" });
        const result = try std.fs.path.join(state.gpa, &.{ state.path, name, "image" });
        try docker.run(&.{ "build", "--platform", platform, "--file", dockerfile, "--iidfile", result, context }, 1800);
        const id = try temporary.readFileAlloc(state.io, "image", state.gpa, .limited(128));
        try state.select(std.mem.trim(u8, id, " \r\n\t"));
    } else {
        if (image.len == 0 and try state.image() != null) return;
        const requested = if (image.len == 0) default_image else image;
        const present = try docker.capture(&.{ "image", "inspect", requested });
        if (!present.term.success()) {
            docker.run(&.{ "pull", requested }, 1800) catch |err| {
                log.err(state.io, "could not obtain image {s}; select a published --image or use --build with a prepared Linux product", .{requested});
                return err;
            };
        }
        try state.select(try docker.query(&.{ "image", "inspect", "--format", "{{.Id}}", requested }));
    }
}

pub fn up(docker: Docker) !void {
    const networks = try docker.query(&.{ "network", "ls", "--format", "{{.Name}}" });
    if (!config.containsLine(networks, "glowcap-rooms-net")) try docker.run(&.{ "network", "create", "glowcap-rooms-net" }, 30);
    docker.run(try docker.composeArgs(&.{ "up", "-d", "--force-recreate", "--wait", "--wait-timeout", "210" }), 240) catch |err| {
        log.err(docker.io, "deployment did not become healthy; inspect `glowcap apps rooms deployment logs` using the same --dir", .{});
        return err;
    };
    const locator = try docker.query(try docker.composeArgs(&.{ "exec", "-T", "directory", "/runtime/bin/glowcap", "apps", "rooms", "locator" }));
    const revision = try docker.query(try docker.composeArgs(&.{ "exec", "-T", "directory", "/runtime/bin/glowcap", "apps", "rooms", "revision" }));
    const session = try docker.query(try docker.composeArgs(&.{ "exec", "-T", "session", "/runtime/bin/glowcap", "apps", "rooms", "session", "ready", "--file=/run/rooms-session/admin.sturdyref" }));
    const capabilities = try docker.query(try docker.composeArgs(&.{ "exec", "-T", "directory", "/runtime/bin/glowcap", "apps", "rooms", "directory", "capabilities" }));
    try stdout(docker.io, try std.fmt.allocPrint(docker.gpa, "\nDirectory operator capabilities:\n{s}\n\nRoom locator:\n{s}\n\nBrowser revision:\n{s}\n\nShared-session administrator capability:\n{s}\n", .{ capabilities, locator, revision, session }));
}

pub const Unit = enum {
    session,
    state,
    storage,
    all,

    fn volume(self: Unit) []const u8 {
        return switch (self) {
            .session => "glowcap-rooms-session-state",
            .state => "glowcap-rooms-directory-state",
            .storage => "glowcap-rooms-postgres",
            .all => unreachable,
        };
    }
};

pub fn reset(docker: Docker, unit: Unit, confirmed: bool) !void {
    const volumes = try docker.query(&.{ "volume", "ls", "--quiet" });
    if (unit != .all and !config.containsLine(volumes, unit.volume())) return error.MissingDeploymentVolume;
    if (!confirmed and !try confirmReset(docker, unit)) {
        log.writeMsg(docker.io, "Reset cancelled; no services or volumes were changed.\n");
        return;
    }
    try docker.run(try docker.composeArgs(&.{"down"}), 120);
    // The override may declare other volumes. Even `all` only removes the
    // three explicit custody units, never every volume Compose can name.
    for ([_]Unit{ .session, .state, .storage }) |candidate| {
        if ((unit == .all or unit == candidate) and config.containsLine(volumes, candidate.volume())) {
            docker.run(&.{ "volume", "rm", candidate.volume() }, 60) catch |err| {
                log.err(docker.io, "reset could not remove {s}; the stack remains stopped and earlier selected volumes may already have been removed. Inspect the data before running deployment up", .{candidate.volume()});
                return err;
            };
        }
    }
    try up(docker);
}

fn confirmReset(docker: Docker, unit: Unit) !bool {
    const tty = Io.Dir.cwd().openFile(docker.io, "/dev/tty", .{}) catch |err| {
        log.err(docker.io, "reset needs an interactive terminal ({s}); use --yes only to confirm destruction without prompting", .{@errorName(err)});
        return error.ConfirmationRequired;
    };
    defer tty.close(docker.io);
    var buffer: [64]u8 = undefined;
    var reader = tty.readerStreaming(docker.io, &buffer);
    const prompt = try std.fmt.allocPrint(docker.gpa, "Destroy {s} permanently and restart? Type yes to confirm, or no to cancel [no]: ", .{@tagName(unit)});
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
