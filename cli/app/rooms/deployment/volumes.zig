//! Compose's resolved mounts own the identity of deployment data. Never infer
//! destruction targets from a default name or a global volume-name prefix.
const std = @import("std");
const Docker = @import("docker.zig").Client;

pub const Kind = enum {
    session,
    state,
    storage,

    fn service(self: Kind) []const u8 {
        return switch (self) {
            .session => "session",
            .state => "directory",
            .storage => "postgres",
        };
    }

    fn target(self: Kind) []const u8 {
        return switch (self) {
            .session => "/session-state",
            .state => "/state",
            .storage => "/var/lib/postgresql",
        };
    }
};

const Mount = struct { type: []const u8, source: ?[]const u8 = null, target: []const u8 };
const Service = struct { volumes: []const Mount = &.{} };
const Volume = struct { name: []const u8, external: bool = false };
const Model = struct {
    services: std.json.ArrayHashMap(Service),
    volumes: std.json.ArrayHashMap(Volume),
};

pub const Selected = struct {
    docker: Docker,
    parsed: std.json.Parsed(Model),

    pub fn load(docker: Docker) !Selected {
        const bytes = try docker.query(try docker.composeArgs(&.{ "config", "--format", "json" }));
        return .{ .docker = docker, .parsed = try std.json.parseFromSlice(Model, docker.gpa, bytes, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) };
    }

    pub fn deinit(self: Selected) void {
        self.parsed.deinit();
    }

    /// Return a copied Docker volume name, after checking its service mount.
    /// External volumes may be inspected for credential protection, never reset.
    pub fn name(self: Selected, kind: Kind, destructive: bool) ![]const u8 {
        const service = self.parsed.value.services.map.get(kind.service()) orelse return error.MissingDeploymentMount;
        var source: ?[]const u8 = null;
        for (service.volumes) |mount| {
            if (!std.mem.eql(u8, mount.target, kind.target())) continue;
            if (source != null) return error.AmbiguousDeploymentMount;
            if (!std.mem.eql(u8, mount.type, "volume")) return error.UnsupportedDeploymentMount;
            source = mount.source orelse return error.MissingDeploymentMount;
        }
        const volume = self.parsed.value.volumes.map.get(source orelse return error.MissingDeploymentMount) orelse
            return error.MissingDeploymentVolume;
        if (destructive and volume.external) return error.ExternalDeploymentVolume;
        if (destructive) {
            var services = self.parsed.value.services.map.iterator();
            while (services.next()) |entry| {
                for (entry.value_ptr.volumes) |mount| {
                    if (std.mem.eql(u8, entry.key_ptr.*, kind.service()) and std.mem.eql(u8, mount.target, kind.target())) continue;
                    if (!std.mem.eql(u8, mount.type, "volume")) continue;
                    const other = self.parsed.value.volumes.map.get(mount.source orelse continue) orelse continue;
                    if (std.mem.eql(u8, volume.name, other.name)) return error.AmbiguousDeploymentVolume;
                }
            }
        }
        if (volume.name.len == 0 or !std.ascii.isAlphanumeric(volume.name[0])) return error.InvalidDeploymentVolume;
        for (volume.name) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return error.InvalidDeploymentVolume;
        }
        return self.docker.gpa.dupe(u8, volume.name);
    }
};
