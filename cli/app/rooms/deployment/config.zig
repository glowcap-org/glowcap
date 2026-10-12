//! Deployment configuration is separate from installations and runtime volumes.
//! Only the base Compose file and selected image are managed. The operator's
//! override and database password are never overwritten by an update.
const std = @import("std");
const log = @import("../../../operability/log.zig");
const Docker = @import("docker.zig").Client;
const Io = std.Io;

pub const Config = struct {
    io: Io,
    gpa: std.mem.Allocator,
    dir: Io.Dir,
    path: []const u8,
    templates: []const u8,

    pub fn read(self: Config, name: []const u8) !?[]const u8 {
        const bytes = self.dir.readFileAlloc(self.io, name, self.gpa, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return bytes;
    }

    pub fn write(self: Config, name: []const u8, bytes: []const u8, replace: bool) !void {
        var file = try self.dir.createFileAtomic(self.io, name, .{ .permissions = .fromMode(0o600), .replace = replace });
        defer file.deinit(self.io);
        try file.file.writeStreamingAll(self.io, bytes);
        try file.file.sync(self.io);
        if (replace) try file.replace(self.io) else try file.link(self.io);
    }

    pub fn template(self: Config, name: []const u8) ![]const u8 {
        const path = try std.fs.path.join(self.gpa, &.{ self.templates, name });
        return Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(1024 * 1024));
    }

    pub fn image(self: Config) !?[]const u8 {
        const bytes = try self.read("image") orelse return null;
        const id = std.mem.trim(u8, bytes, " \t\r\n");
        if (!imageId(id)) return error.InvalidImageSelection;
        return id;
    }

    pub fn select(self: Config, id: []const u8) !void {
        if (!imageId(id)) return error.InvalidImageSelection;
        if (try self.image()) |previous| {
            if (std.mem.eql(u8, previous, id)) return;
            try self.write("previous-image", try std.fmt.allocPrint(self.gpa, "{s}\n", .{previous}), true);
        }
        try self.write("image", try std.fmt.allocPrint(self.gpa, "{s}\n", .{id}), true);
    }

    pub fn databaseSecret(self: Config) !?[]const u8 {
        const secret = try self.read("secrets/storage-db-password") orelse return null;
        if (std.mem.trim(u8, secret, " \r\n").len == 0) {
            log.err(self.io, "database password is empty at {s}/secrets/storage-db-password; restore the original password before starting or resetting the deployment", .{self.path});
            return error.EmptyDatabaseSecret;
        }
        return secret;
    }

    pub fn prepare(self: Config, docker: Docker) !void {
        const secret = try self.databaseSecret();
        const override = "docker-compose.override.yml";
        if (try self.read(override) == null) try self.write(override, try self.template("docker-compose.override.yml.example"), false);
        try self.write("compose.yml", try self.template("docker-compose.yml"), true);
        // Resolve the operator's actual database before minting credentials.
        // A placeholder image lets Compose resolve environment-derived volume
        // names before image selection, without starting any services.
        const secret_name = "secrets/storage-db-password";
        if (secret == null) {
            var inspection_env = try docker.environ.clone(self.gpa);
            if (inspection_env.get("GLOWCAP_ROOMS_IMAGE") == null) try inspection_env.put("GLOWCAP_ROOMS_IMAGE", "glowcap-volume-inspection");
            var inspection = docker;
            inspection.environ = &inspection_env;
            const selected = try @import("volumes.zig").Selected.load(inspection);
            defer selected.deinit();
            const database = try selected.name(.storage, false);
            if (containsLine(try docker.query(&.{ "volume", "ls", "--quiet" }), database)) {
                log.err(self.io, "database volume already exists, but {s}/secrets/storage-db-password is missing; copy its original password and operator override into this directory, use --dir to select their current directory, or restore from backup", .{self.path});
                return error.MissingDatabaseSecret;
            }
            _ = try self.dir.createDirPathStatus(self.io, "secrets", .fromMode(0o700));
            var random: [32]u8 = undefined;
            try self.io.randomSecure(&random);
            try self.write(secret_name, try std.fmt.allocPrint(self.gpa, "{s}\n", .{std.fmt.bytesToHex(random, .lower)}), false);
        }
    }
};

pub fn imageId(id: []const u8) bool {
    if (id.len != 71 or !std.mem.startsWith(u8, id, "sha256:")) return false;
    for (id[7..]) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}

pub fn containsLine(bytes: []const u8, value: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, std.mem.trim(u8, line, " \r\t"), value)) return true;
    return false;
}

/// What a prepared product says about itself: the Docker platform it runs on
/// and the source revision it was built from, which an image built from it
/// carries as its OCI revision label.
pub const Release = struct {
    platform: []const u8,
    /// `<commit>`, or `<commit>-dirty` when the build saw uncommitted changes.
    /// Null when the product did not record one.
    revision: ?[]const u8,
};

/// The OCI label an image built from a product carries its revision in.
pub const revision_label = "org.opencontainers.image.revision";

pub fn productRelease(io: Io, gpa: std.mem.Allocator, product: []const u8) !Release {
    const path = try std.fs.path.join(gpa, &.{ product, "share/glowcap/release.json" });
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    const metadata = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{ .allocate = .alloc_always });
    const fields = if (metadata.value == .object) metadata.value.object else {
        log.err(io, "Docker needs a Linux product; run `zig build rooms-release` in the Linux devcontainer and pass its product directory with --build", .{});
        return error.InvalidProductTarget;
    };
    const platform: []const u8 = platform: {
        if (fields.get("target")) |target| if (target == .string) {
            if (std.mem.eql(u8, target.string, "aarch64-linux")) break :platform "linux/arm64";
            if (std.mem.eql(u8, target.string, "x86_64-linux")) break :platform "linux/amd64";
        };
        log.err(io, "Docker needs a Linux product; run `zig build rooms-release` in the Linux devcontainer and pass its product directory with --build", .{});
        return error.InvalidProductTarget;
    };
    const commit = if (fields.get("revision")) |value| if (value == .string and value.string.len != 0) value.string else null else null;
    const dirty = if (fields.get("dirty")) |value| value == .bool and value.bool else false;
    return .{
        .platform = platform,
        .revision = if (commit) |c| if (dirty) try std.fmt.allocPrint(gpa, "{s}-dirty", .{c}) else c else null,
    };
}

pub fn linuxPlatform(io: Io, gpa: std.mem.Allocator, product: []const u8) ![]const u8 {
    return (try productRelease(io, gpa, product)).platform;
}
