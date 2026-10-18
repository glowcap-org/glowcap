//! Host construction and transactional provider-registry admission.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");
const driver_core = @import("driver_core");

const contract = @import("contract.zig");
const provider_package = @import("provider_package.zig");
const runtime_transports = @import("transports.zig");
const runtime = @import("../host_runtime.zig");
const HostRuntime = runtime.HostRuntime;
const Internal = runtime.Internal;
const Error = driver_core.Error;

pub fn providerFor(self: *const HostRuntime, transport: []const u8) ?provider_package.Selected {
    for (self.providers.items) |provider|
        if (std.mem.eql(u8, provider.transport, transport)) return provider;
    return null;
}

pub fn mintRuntimeId(next: *usize) !usize {
    const id = next.*;
    if (id == 0 or id == std.math.maxInt(usize)) return error.IdentifierExhausted;
    next.* = id + 1;
    return id;
}

pub fn hasTransport(self: *const HostRuntime, transport: []const u8) bool {
    return providerFor(self, transport) != null;
}

pub fn transportName(self: *const HostRuntime, transport: []const u8) ?[]const u8 {
    return (providerFor(self, transport) orelse return null).transport;
}

/// Construct the runtime over the transports one value names.
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    transports: runtime_transports.Transports,
    identity: driver_core.Identity,
    opts: HostRuntime.Options,
) !HostRuntime {
    if (opts.frame_cap == 0 or opts.wire_buffer_bytes == 0 or opts.max_pending_opens == 0)
        return Error.InvalidBufferConfiguration;
    if (opts.busy_poll_ns > HostRuntime.max_busy_poll_ns) return Error.BusyPollWindowTooLong;
    const seed: [foundation.crypto.seed_bytes]u8 = switch (identity) {
        .keyed => |keyed| keyed.secret.seed(),
        .ephemeral => blk: {
            var value: [foundation.crypto.seed_bytes]u8 = undefined;
            io.randomSecure(&value) catch return Error.HandshakeEntropyFailed;
            break :blk value;
        },
    };
    // Session signing roots belong at this I/O entropy boundary; the sans-io
    // core draws none and a restarted Host must not recreate handoff names.
    var session_root: [foundation.crypto.seed_bytes]u8 = undefined;
    io.randomSecure(&session_root) catch return Error.HandshakeEntropyFailed;
    const core = try allocator.create(driver_core.Host);
    var core_opts = driver_core.Host.Options{
        .codec = opts.codec,
        .captp_version = opts.captp_version,
        .features = opts.features,
    };
    core_opts.limits.max_frame_bytes = opts.frame_cap;
    core.* = try driver_core.Host.init(allocator, seed, session_root, core_opts);
    var result = HostRuntime{ .allocator = allocator, .io = io, .core = core, .opts = opts, .drive = .blocking };
    errdefer result.deinit();
    // The drive is chosen inside the teardown's scope: a stepped face that
    // cannot open its readiness set fails construction whole.
    result.drive = try HostRuntime.Drive.init(opts.drive);
    try runtime_transports.install(&result, transports);
    return result;
}

pub fn initWithCore(
    allocator: std.mem.Allocator,
    io: std.Io,
    core: *driver_core.Host,
    transports: runtime_transports.Transports,
    adoption: HostRuntime.AdoptionOptions,
) !HostRuntime {
    const opts = HostRuntime.Options{
        .frame_cap = core.opts.limits.max_frame_bytes,
        .wire_buffer_bytes = adoption.wire_buffer_bytes,
        .max_pending_opens = adoption.max_pending_opens,
        .codec = core.opts.codec,
        .captp_version = core.opts.captp_version,
        .features = core.opts.features,
        .handshake = adoption.handshake,
        .listener_setup = adoption.listener_setup,
        .settle = adoption.settle,
        .unhandled_failure = null,
        .busy_poll_ns = adoption.busy_poll_ns,
    };
    if (opts.frame_cap == 0 or opts.wire_buffer_bytes == 0 or opts.max_pending_opens == 0)
        return Error.InvalidBufferConfiguration;
    if (opts.busy_poll_ns > HostRuntime.max_busy_poll_ns) return Error.BusyPollWindowTooLong;
    try core.checkRuntimeAdoption();
    var result = HostRuntime{
        .allocator = allocator,
        .io = io,
        .core = core,
        .opts = opts,
        .drive = .blocking,
        .owns_core = false,
    };
    errdefer result.deinitAfterFailedAdoption();
    result.drive = try HostRuntime.Drive.init(adoption.drive);
    try runtime_transports.install(&result, transports);
    return result;
}

pub fn addResident(self: *HostRuntime, profile: model.transport.Metadata, resident: net.MultiplexedResident) !usize {
    var index: [1]usize = undefined;
    try addProviders(self, &.{.{ .profile = profile, .resident = resident }}, &index);
    return index[0];
}

/// Install a provider package only after all validation and capacity succeeds.
pub fn addProviderPackage(self: *HostRuntime, package: HostRuntime.ProviderPackage, indices: []usize) !bool {
    try Internal.admitApplicationOperation(self);
    if (package.registrations.len == 0 or indices.len != package.registrations.len)
        return error.InvalidProviderPackage;
    for (self.provider_packages.items) |installed| {
        if (!try installed.overlaps(package.registrations)) continue;
        if (!try installed.hasSameProfiles(package.registrations)) return error.ProviderConfigurationConflict;
        if (try installed.owner.same_configuration(installed.owner.ctx, package.owner.ctx)) return false;
        return error.ProviderConfigurationConflict;
    }
    const profiles = try self.allocator.alloc(model.transport.Metadata, package.registrations.len);
    errdefer self.allocator.free(profiles);
    try self.provider_packages.ensureUnusedCapacity(self.allocator, 1);
    try addProvidersAfterAdmission(self, package.registrations, indices);
    for (package.registrations, profiles) |registration, *profile| {
        profile.* = try contract.canonicalProviderProfile(registration.profile);
        profile.symbol = self.transportName(profile.symbol).?;
    }
    self.provider_packages.appendAssumeCapacity(.{ .profiles = profiles, .owner = package.owner });
    return true;
}

pub fn addProviders(self: *HostRuntime, registrations: []const HostRuntime.ProviderRegistration, indices: []usize) !void {
    try Internal.admitApplicationOperation(self);
    try addProvidersAfterAdmission(self, registrations, indices);
}

fn addProvidersAfterAdmission(self: *HostRuntime, registrations: []const HostRuntime.ProviderRegistration, indices: []usize) !void {
    if (registrations.len == 0 or indices.len != registrations.len) return error.InvalidProviderPackage;
    const Prepared = struct {
        profile: model.transport.Metadata,
        source: union(enum) { resident: usize, new_resident: struct { index: usize, readiness_fd: i32 } },
        fn residentIndex(plan: @This()) usize {
            return switch (plan.source) {
                .resident => |index| index,
                .new_resident => |value| value.index,
            };
        }
    };
    const prepared = try self.allocator.alloc(Prepared, registrations.len);
    defer self.allocator.free(prepared);
    const profiles = try self.allocator.alloc(model.transport.Metadata, registrations.len);
    defer self.allocator.free(profiles);
    var new_resident_count: usize = 0;
    for (registrations, prepared, 0..) |registration, *plan, i| {
        const profile = try contract.canonicalProviderProfile(registration.profile);
        if (self.hasTransport(profile.symbol)) return error.TransportAlreadyRegistered;
        for (prepared[0..i]) |prior|
            if (std.mem.eql(u8, prior.profile.symbol, profile.symbol)) return error.TransportAlreadyRegistered;
        var index: ?usize = null;
        for (self.residents.items, 0..) |existing, existing_index| if (existing.resident.eql(registration.resident)) {
            index = existing_index;
            break;
        };
        if (index == null) for (registrations[0..i], 0..) |prior, prior_index| {
            if (prior.resident.eql(registration.resident)) {
                index = prepared[prior_index].residentIndex();
                break;
            }
        };
        if (index) |existing_index| {
            plan.* = .{ .profile = profile, .source = .{ .resident = existing_index } };
            continue;
        }
        const readiness_fd = registration.resident.readinessFd();
        if (readiness_fd < 0) return error.ReadinessUnavailable;
        if (Internal.descriptorInUse(self, readiness_fd)) return error.ReadinessDescriptorConflict;
        for (prepared[0..i]) |prior| switch (prior.source) {
            .new_resident => |value| if (value.readiness_fd == readiness_fd)
                return error.ReadinessDescriptorConflict,
            else => {},
        };
        const new_index = self.residents.items.len + new_resident_count;
        new_resident_count += 1;
        plan.* = .{ .profile = profile, .source = .{ .new_resident = .{
            .index = new_index,
            .readiness_fd = readiness_fd,
        } } };
    }
    for (prepared, profiles) |plan, *profile| profile.* = plan.profile;
    const canonical = try self.allocator.alloc([]const u8, registrations.len);
    defer self.allocator.free(canonical);
    const readiness_fds = try self.allocator.alloc(i32, new_resident_count);
    defer self.allocator.free(readiness_fds);
    try self.providers.ensureUnusedCapacity(self.allocator, registrations.len);
    try self.residents.ensureUnusedCapacity(self.allocator, new_resident_count);
    var readiness_added: usize = 0;
    errdefer for (readiness_fds[0..readiness_added]) |fd| Internal.removeReadyFd(self, fd);
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| for (prepared) |plan| {
            const fd = switch (plan.source) {
                .new_resident => |value| value.readiness_fd,
                else => continue,
            };
            try stepped.ready_set.add(fd);
            readiness_fds[readiness_added] = fd;
            readiness_added += 1;
        },
    }
    try self.core.defineTransports(profiles, canonical);
    for (registrations, prepared, canonical, indices) |registration, plan, transport, *out_index| {
        const index = plan.residentIndex();
        switch (plan.source) {
            .new_resident => |value| {
                std.debug.assert(value.index == self.residents.items.len);
                self.residents.appendAssumeCapacity(.{
                    .resident = registration.resident,
                    .readiness_fd = value.readiness_fd,
                });
            },
            .resident => {},
        }
        self.providers.appendAssumeCapacity(.{
            .transport = transport,
            .designator_scheme = registration.profile.designator_scheme,
            .resident = index,
        });
        out_index.* = index;
    }
}
