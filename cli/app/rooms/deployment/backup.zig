//! Describe the mounts in the selected deployment before its operator stops it.
//! A restored external volume can have any name and need not carry Compose labels.
const std = @import("std");
const Config = @import("config.zig").Config;
const Docker = @import("docker.zig").Client;
const members = @import("members.zig");
const Selected = @import("volumes.zig").Selected;
const Parsed = @import("../../../cmd/types.zig").Parsed;
const log = @import("../../../operability/log.zig");
const stdout = @import("../../../argv.zig").writeStdout;

const Stage = enum { served, agent_unstarted, files_only };

const Project = struct {
    owner: []const u8,
    selected: Selected,
    stage: Stage,
    missing_link: ?[]const u8,
};

const Inventory = struct {
    projects: std.ArrayList(Project) = .empty,
    containers: std.array_hash_map.String(Selected) = .empty,
    volumes: std.array_hash_map.String(void) = .empty,

    fn collect(self: *Inventory, docker: Docker, base: []const []const u8, owner: []const u8, stage: Stage, missing_link: ?[]const u8) !void {
        const args = try std.mem.concat(docker.gpa, []const u8, &.{ base, &.{ "config", "--format", "json" } });
        const selected = try Selected.loadArgs(docker, args);
        try self.projects.append(docker.gpa, .{ .owner = owner, .selected = selected, .stage = stage, .missing_link = missing_link });
        for (selected.parsed.value.volumes.map.values()) |volume| try self.volumes.put(docker.gpa, volume.name, {});
        const ps = try std.mem.concat(docker.gpa, []const u8, &.{ base, &.{ "ps", "--all", "--no-trunc", "--quiet" } });
        const current = try docker.query(ps);
        if (stage == .files_only and (current.len != 0 or missing_link == null)) return error.MemberAlreadyStarted;
        var ids = std.mem.tokenizeScalar(u8, current, '\n');
        while (ids.next()) |id| try self.containers.put(docker.gpa, id, selected);
    }

    fn existing(self: Inventory, docker: Docker) !std.StringHashMapUnmanaged(void) {
        var found: std.StringHashMapUnmanaged(void) = .empty;
        if (self.volumes.count() == 0) return found;
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(docker.gpa, &.{ "volume", "ls", "--quiet" });
        for (self.volumes.keys()) |name| try args.appendSlice(docker.gpa, &.{ "--filter", try docker.gpa.print("name={s}", .{name}) });
        var lines = std.mem.tokenizeScalar(u8, try docker.query(args.items), '\n');
        while (lines.next()) |line| try found.put(docker.gpa, line, {});
        return found;
    }
};

pub fn plan(state: Config, docker: Docker, parsed: *Parsed) !void {
    const names = try members.inventory(state, true);
    var stages: std.StringHashMapUnmanaged(Stage) = .empty;
    for ([_][]const u8{ "unstarted", "files-only" }, [_]Stage{ .agent_unstarted, .files_only }) |flag, stage| {
        const values = parsed.repeated.get(flag) orelse continue;
        for (values.items) |nick| {
            for (names) |name| {
                if (std.mem.eql(u8, name, nick)) break;
            } else return error.BotNotInitialized;
            const entry = try stages.getOrPut(state.gpa, nick);
            if (entry.found_existing) return error.DuplicateBotName;
            entry.value_ptr.* = stage;
        }
    }
    var inventory: Inventory = .{};
    try inventory.collect(docker, try docker.composeArgs(&.{}), "@base", .served, null);
    for (names) |nick| {
        const path = try std.Io.Dir.path.join(state.gpa, &.{ state.path, "bots", nick });
        const dir = try std.Io.Dir.cwd().openDir(state.io, path, .{});
        defer dir.close(state.io);
        const member: Config = .{ .io = state.io, .gpa = state.gpa, .dir = dir, .path = path, .templates = state.templates };
        const compose = try members.composeFor(state, member, docker, try members.projectName(state, nick));
        const missing_link = if (try member.exists("bot-link")) null else try std.Io.Dir.path.join(state.gpa, &.{ path, "bot-link" });
        try inventory.collect(docker, compose.base, nick, stages.get(nick) orelse .served, missing_link);
    }
    const existing = try inventory.existing(docker);
    try verifyContainers(docker, inventory);
    var manifest: std.ArrayList(u8) = .empty;
    for (inventory.projects.items) |project| try describe(docker, project, existing, &manifest);
    try stdout(state.io, manifest.items);
}

fn describe(docker: Docker, project: Project, existing: std.StringHashMapUnmanaged(void), manifest: *std.ArrayList(u8)) !void {
    const model = project.selected.parsed.value;
    const owner = project.owner;
    const named = !std.mem.eql(u8, owner, "@base");
    if (named) try manifest.print(docker.gpa, "member\t{s}\t-\t-\t-\n", .{owner});
    const required: []const [2][]const u8 = if (named)
        &.{ .{ "member-session", "/session-state" }, .{ "bot", "/bot-state" }, .{ "bot", "/bot-state/home" } }
    else
        &.{ .{ "directory", "/state" }, .{ "session", "/session-state" } };
    for (required) |entry| {
        const service = model.services.map.get(entry[0]) orelse return error.MissingDeploymentMount;
        for (service.volumes) |mount| {
            if (std.mem.eql(u8, mount.target, entry[1]) and (std.mem.eql(u8, mount.type, "volume") or std.mem.eql(u8, mount.type, "bind"))) break;
        } else return error.MissingDeploymentMount;
    }
    var services = model.services.map.iterator();
    while (services.next()) |entry| {
        const service = entry.key_ptr.*;
        for (entry.value_ptr.volumes) |mount| {
            if (std.mem.eql(u8, mount.type, "tmpfs")) continue;
            const source = mount.source orelse return error.MissingDeploymentMount;
            var kind = mount.type;
            var logical = source;
            var location = source;
            if (std.mem.eql(u8, kind, "volume")) {
                const volume = model.volumes.map.get(source) orelse return error.MissingDeploymentVolume;
                location = volume.name;
                const state_slot = for (required) |slot| {
                    if (std.mem.eql(u8, service, slot[0]) and std.mem.eql(u8, mount.target, slot[1])) break true;
                } else false;
                if (existing.contains(location)) {
                    if (project.stage == .files_only and state_slot) return error.MemberAlreadyStarted;
                } else {
                    const may_be_uncreated = (project.stage == .files_only and (state_slot or !volume.external)) or
                        (project.stage == .agent_unstarted and state_slot and std.mem.eql(u8, service, "bot"));
                    if (!may_be_uncreated) {
                        log.err(docker.io, "{s}: missing Docker volume {s} at {s} {s}. Check the saved configuration and recover the volume. Use --unstarted only for an unstarted agent, or --files-only if even its session has never started", .{ owner, location, service, mount.target });
                        return error.MissingDeploymentVolume;
                    }
                    kind = "uncreated";
                }
            } else if (std.mem.eql(u8, kind, "bind")) {
                _ = std.Io.Dir.cwd().statFile(docker.io, source, .{}) catch |err| {
                    log.err(docker.io, "{s}: cannot back up bind mount {s} ({s})", .{ owner, source, @errorName(err) });
                    return err;
                };
                logical = "-";
            } else return error.UnsupportedDeploymentMount;
            const use = try docker.gpa.print("{s}:{s}", .{ service, mount.target });
            try appendRow(docker, manifest, kind, owner, use, logical, location);
        }
        try resources(docker, project, manifest, service, entry.value_ptr.secrets, model.secrets, "/run/secrets/");
        try resources(docker, project, manifest, service, entry.value_ptr.configs, model.configs, "/");
    }
}

fn appendRow(docker: Docker, manifest: *std.ArrayList(u8), kind: []const u8, owner: []const u8, use: []const u8, logical: []const u8, location: []const u8) !void {
    for ([_][]const u8{ logical, location, use }) |field| {
        if (field.len == 0 or std.mem.findAny(u8, field, "\t\r\n") != null) return error.InvalidManifestField;
    }
    try manifest.print(docker.gpa, "{s}\t{s}\t{s}\t{s}\t{s}\n", .{ kind, owner, use, logical, location });
}

fn resources(docker: Docker, project: Project, manifest: *std.ArrayList(u8), service: []const u8, attachments: anytype, definitions: anytype, directory: []const u8) !void {
    for (attachments) |attachment| {
        const resource = definitions.map.get(attachment.source) orelse return error.MissingDeploymentResource;
        const target = attachment.target orelse attachment.source;
        const path = if (std.mem.startsWith(u8, target, "/")) target else try docker.gpa.print("{s}{s}", .{ directory, target });
        const use = try docker.gpa.print("{s}:{s}", .{ service, path });
        var kind: []const u8 = if (resource.file != null) "file" else if (resource.environment != null) "environment" else if (resource.external) "external" else "inline";
        const location = resource.file orelse resource.environment orelse resource.name orelse attachment.source;
        if (resource.file) |file| {
            if (std.Io.Dir.cwd().statFile(docker.io, file, .{})) |_| {} else |err| {
                // The bot's very first link only comes into existence on successful grant issue.
                if (err == error.FileNotFound and project.stage != .served and std.mem.eql(u8, project.missing_link orelse "", file)) {
                    kind = "uncreated";
                } else {
                    log.err(docker.io, "{s}: cannot back up {s} at {s} ({s})", .{ project.owner, attachment.source, file, @errorName(err) });
                    return err;
                }
            }
        }
        try appendRow(docker, manifest, kind, project.owner, use, attachment.source, location);
    }
}

fn verifyContainers(docker: Docker, inventory: Inventory) !void {
    if (inventory.containers.count() == 0) return;
    const inspect = try std.mem.concat(docker.gpa, []const u8, &.{ &.{ "inspect", "--format", "{{.Id}}\t{{index .Config.Labels \"com.docker.compose.service\"}}\t{{json .Mounts}}" }, inventory.containers.keys() });
    var containers = std.mem.tokenizeScalar(u8, try docker.query(inspect), '\n');
    while (containers.next()) |row| {
        var fields = std.mem.splitScalar(u8, row, '\t');
        const selected = inventory.containers.get(fields.first()) orelse return error.InvalidDockerResponse;
        const service_name = fields.next() orelse return error.InvalidDockerResponse;
        const actual = try std.json.parseFromSlice([]const DockerMount, docker.gpa, fields.rest(), .{ .ignore_unknown_fields = true });
        defer actual.deinit();
        verifyMounts(selected, service_name, actual.value) catch |err| {
            log.err(docker.io, "the mounts attached to {s} differ from its selected Compose configuration. Keep the services and recover the matching override before backup", .{service_name});
            return err;
        };
    }
}

const DockerMount = struct { Type: []const u8, Destination: []const u8, Name: ?[]const u8 = null, Source: []const u8 };

fn verifyMounts(selected: Selected, service_name: []const u8, actual: []const DockerMount) !void {
    const service = selected.parsed.value.services.map.get(service_name) orelse return error.UnconfiguredDeploymentService;
    for (service.volumes) |mount| {
        if (std.mem.eql(u8, mount.type, "tmpfs")) continue;
        const source = mount.source orelse return error.MissingDeploymentMount;
        const location = if (std.mem.eql(u8, mount.type, "volume")) blk: {
            const volume = selected.parsed.value.volumes.map.get(source) orelse return error.MissingDeploymentVolume;
            break :blk volume.name;
        } else source;
        for (actual) |attached| {
            if (!std.mem.eql(u8, mount.target, attached.Destination)) continue;
            const current = if (std.mem.eql(u8, attached.Type, "volume")) attached.Name orelse return error.MissingDeploymentVolume else attached.Source;
            if (!std.mem.eql(u8, mount.type, attached.Type) or !std.mem.eql(u8, location, current)) return error.DeploymentMountChanged;
            break;
        } else return error.DeploymentMountChanged;
    }
    try verifyResources(service.secrets, selected.parsed.value.secrets, "/run/secrets/", actual);
    try verifyResources(service.configs, selected.parsed.value.configs, "/", actual);
    for (actual) |attached| {
        if (std.mem.eql(u8, attached.Type, "tmpfs")) continue;
        const path = attached.Destination;
        // Compose also attaches its declared file-backed secrets and configs.
        for (service.volumes) |mount| {
            if (std.mem.eql(u8, mount.target, path)) break;
        } else if (!hasAttachment(service.secrets, "/run/secrets/", path) and !hasAttachment(service.configs, "/", path)) return error.UnconfiguredDeploymentMount;
    }
}

fn verifyResources(attachments: anytype, definitions: anytype, directory: []const u8, actual: []const DockerMount) !void {
    for (attachments) |attachment| {
        const resource = definitions.map.get(attachment.source) orelse return error.MissingDeploymentResource;
        const file = resource.file orelse continue;
        for (actual) |mount| {
            if (!attachment.matches(directory, mount.Destination)) continue;
            if (!std.mem.eql(u8, mount.Type, "bind") or !std.mem.eql(u8, mount.Source, file)) return error.DeploymentMountChanged;
            break;
        } else return error.DeploymentMountChanged;
    }
}

fn hasAttachment(attachments: anytype, directory: []const u8, path: []const u8) bool {
    for (attachments) |attachment| if (attachment.matches(directory, path)) return true;
    return false;
}
