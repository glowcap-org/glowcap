//! Own the driver's generic transport-provider seam.
//!
//! This facade admits provider packages and owns their copied callbacks and
//! leases. Private stream and multiplexed owners adapt execution tables to
//! `HostRuntime` contracts without knowing a concrete transport.

const std = @import("std");

const model = @import("model");
const driver = @import("driver");
const owner_mod = @import("provider_registry/owner.zig");
const install_outcome = @import("provider_registry/install_outcome.zig");
const stream_adapter = @import("provider_registry/stream_resident.zig");
const multiplexed_adapter = @import("provider_registry/multiplexed.zig");
const validation = @import("provider_registry/validation.zig");
const driver_error = @import("error.zig");
const failure_output = @import("failure_output.zig");

const shared = @import("c_abi_shared");

const Owner = owner_mod.Owner;

const GLOWCAP_OK = shared.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = shared.GLOWCAP_ERR_NULL_POINTER;

pub const ProviderInstallOutcome = install_outcome.Outcome;

const PreparedPackage = struct {
    owner: *Owner,
    adapters: []Adapter,
    lease_ctx: ?*anyopaque,
    same_configuration: shared.transport_provider.GlowcapTransportProviderSameConfigurationFn,
    release: shared.transport_provider.GlowcapTransportReleaseFn,

    fn runtimeOwner(self: *PreparedPackage) driver.HostRuntime.ProviderOwner {
        return .{ .ctx = self, .same_configuration = sameConfiguration, .release = releaseOwner };
    }

    fn sameConfiguration(installed_raw: *anyopaque, candidate_raw: *anyopaque) anyerror!bool {
        const installed: *PreparedPackage = @ptrCast(@alignCast(installed_raw));
        const candidate: *PreparedPackage = @ptrCast(@alignCast(candidate_raw));
        if (installed.same_configuration != candidate.same_configuration) return false;
        return switch (installed.same_configuration(installed.lease_ctx, candidate.lease_ctx)) {
            0 => false,
            1 => true,
            else => {
                installed.owner.failContract("same_configuration returned a value other than 0 or 1");
                return error.ProviderContract;
            },
        };
    }

    fn releaseOwner(raw: *anyopaque) ?driver.OperationFailure {
        const self: *PreparedPackage = @ptrCast(@alignCast(raw));
        const owner = self.owner;
        var failure: ?driver.OperationFailure = null;
        for (self.adapters) |adapter| if (adapter.deinit(owner)) |cleanup| {
            if (failure) |*first| first.noteFailure(cleanup) else failure = cleanup;
        };
        owner.allocator.free(self.adapters);
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.release(self.lease_ctx, &report);
        if (owner.providerCallbackFailure(code, report, "provider package release")) |released| {
            if (failure) |*first| first.noteFailure(released) else failure = released;
        }
        owner.allocator.destroy(self);
        return failure;
    }
};

const PreparedEntry = struct {
    profile: model.transport.Metadata,
    adapter: Adapter,
    /// The provider table's address is multiplexed runtime identity within one
    /// package preparation. Only multiplexed entries may share it. The table is
    /// copied once, then every profile points at that adapter.
    implementation: *const anyopaque,

    fn registration(self: PreparedEntry) driver.HostRuntime.ProviderRegistration {
        return self.adapter.registration(self.profile);
    }
};

pub const Registry = struct {
    owner: Owner,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, runtime: *driver.HostRuntime) Registry {
        return .{ .owner = Owner.init(allocator, io, runtime) };
    }

    pub fn deinit(self: *Registry) void {
        self.* = undefined;
    }

    /// Install one package atomically. Every profile and implementation table
    /// is validated and allocated before HostRuntime publishes any registration.
    pub fn addProvider(
        self: *Registry,
        provider: ?*const shared.GlowcapTransportProvider,
    ) ProviderInstallOutcome {
        const package = provider orelse
            return .fromCode(GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
        self.owner.runtime.checkApplicationAdmission() catch |err| return errorOutcome(err);
        if (package.abi_version != shared.transport_provider.GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION or
            package.struct_size < @sizeOf(shared.GlowcapTransportProvider) or
            package.entry_count == 0 or package.entries == null or
            package.same_configuration == null or package.retain == null or package.release == null)
        {
            return refusePackage("driver: invalid transport provider package");
        }

        const entries = package.entries.?[0..package.entry_count];
        const decoded_profiles = self.owner.allocator.alloc(model.transport.Metadata, entries.len) catch
            return .fromError(error.OutOfMemory);
        defer self.owner.allocator.free(decoded_profiles);
        // An entry is well formed or not on its own, whatever is installed,
        // and a malformed one is refused before the package's lease is taken.
        for (entries, decoded_profiles, 0..) |entry, *profile, i| {
            const profile_table = entry.profile orelse
                return refusePackage("driver: provider entry has no transport profile");
            profile.* = validation.transportProfile(profile_table) catch |err| return errorOutcome(err);
            for (decoded_profiles[0..i]) |prior| {
                if (std.mem.eql(u8, prior.symbol, profile.symbol))
                    return refusePackage("driver: provider package names one transport twice");
            }
            validateEntry(entry, entries[0..i]) catch |err|
                return if (err == error.InvalidProviderPackage) .fromError(err) else errorOutcome(err);
        }

        var retain_report = shared.transport_provider.emptyProviderFailure();
        const retain_code = package.retain.?(package.lease_ctx, &retain_report);
        if (self.owner.providerCallbackFailure(retain_code, retain_report, "provider package retain")) |retain_failure| {
            var failure = retain_failure;
            // A success status commits the lease even when its contradictory
            // diagnostic makes the callback a contract failure. Retire that
            // lease before refusing registration.
            if (retain_code == GLOWCAP_OK) {
                var release_report = shared.transport_provider.emptyProviderFailure();
                const release_code = package.release.?(package.lease_ctx, &release_report);
                if (self.owner.providerCallbackFailure(
                    release_code,
                    release_report,
                    "provider package retain rollback",
                )) |cleanup| failure.noteFailure(cleanup);
            }
            failure_output.setLastError("driver provider retain", failure);
            return .{ .result = driver_error.code(failure.kind()), .failure = failure };
        }

        var lease_consumed = false;
        const result = self.addRetainedProvider(package, entries, decoded_profiles, &lease_consumed);
        if (lease_consumed) return result;
        var release_report = shared.transport_provider.emptyProviderFailure();
        const release_code = package.release.?(package.lease_ctx, &release_report);
        var outcome = result;
        if (self.owner.providerCallbackFailure(
            release_code,
            release_report,
            "provider package rollback release",
        )) |cleanup| outcome.note(cleanup);
        if (outcome.failure) |failure| failure_output.setLastError("driver provider registration", failure);
        return outcome;
    }

    fn addRetainedProvider(
        self: *Registry,
        package: *const shared.GlowcapTransportProvider,
        entries: []const shared.GlowcapTransportProviderEntry,
        decoded_profiles: []const model.transport.Metadata,
        lease_consumed: *bool,
    ) ProviderInstallOutcome {
        // Compose before building anything: a stream adapter owns an I/O
        // backend, so only the profiles this package will serve get one.
        const unserved = self.owner.allocator.alloc(bool, entries.len) catch
            return .fromError(error.OutOfMemory);
        defer self.owner.allocator.free(unserved);
        var candidate: PreparedPackage = .{
            .owner = &self.owner,
            .adapters = &.{},
            .lease_ctx = package.lease_ctx,
            .same_configuration = package.same_configuration.?,
            .release = package.release.?,
        };
        const count = self.owner.runtime.unservedProfiles(decoded_profiles, candidate.runtimeOwner(), unserved) catch |err|
            return errorOutcome(err);
        if (count == 0) return .{};

        const prepared_entries = self.owner.allocator.alloc(PreparedEntry, count) catch
            return .fromError(error.OutOfMemory);
        defer self.owner.allocator.free(prepared_entries);
        const owned_adapters = self.owner.allocator.alloc(Adapter, count) catch
            return .fromError(error.OutOfMemory);
        defer self.owner.allocator.free(owned_adapters);
        var prepared: usize = 0;
        var owned: usize = 0;
        var published = false;
        defer if (!published) for (owned_adapters[0..owned]) |adapter| {
            if (adapter.deinit(&self.owner)) |cleanup| self.owner.runtime.reportUnhandledFailure(cleanup);
        };

        for (entries, decoded_profiles, unserved) |entry, profile, wanted| {
            if (!wanted) continue;
            const implementation = entry.implementation.?;
            const prepared_entry = &prepared_entries[prepared];
            const adapter = self.prepareAdapter(
                entry,
                profile,
                implementation,
                prepared_entries[0..prepared],
                owned_adapters,
                &owned,
            ) catch |err| return errorOutcome(err);
            prepared_entry.* = .{
                .profile = profile,
                .adapter = adapter,
                .implementation = implementation,
            };
            prepared += 1;
        }

        const registrations = self.owner.allocator.alloc(driver.HostRuntime.ProviderRegistration, count) catch
            return .fromError(error.OutOfMemory);
        defer self.owner.allocator.free(registrations);
        for (prepared_entries, registrations) |entry, *registration| {
            registration.* = entry.registration();
        }

        const adapter_owners = self.owner.allocator.dupe(Adapter, owned_adapters[0..owned]) catch
            return .fromError(error.OutOfMemory);
        var adapter_owners_live = true;
        defer if (adapter_owners_live) self.owner.allocator.free(adapter_owners);
        const prepared_package = self.owner.allocator.create(PreparedPackage) catch
            return .fromError(error.OutOfMemory);
        candidate.adapters = adapter_owners;
        prepared_package.* = candidate;
        adapter_owners_live = false;
        published = true;
        lease_consumed.* = true;
        self.owner.runtime.addProviderPackage(.{
            .registrations = registrations,
            .owner = prepared_package.runtimeOwner(),
        }) catch |err| {
            var failure = driver.OperationFailure.fromError(err);
            if (PreparedPackage.releaseOwner(prepared_package)) |cleanup| failure.noteFailure(cleanup);
            failure_output.setLastError("driver provider registration", failure);
            return .{ .result = driver_error.code(failure.kind()), .failure = failure };
        };
        return .{};
    }

    /// Build the adapter of one validated entry. A stream profile owns its
    /// own adapter. Multiplexed profiles that name one table share one
    /// adapter, which is prepared on first sight and appended to
    /// `owned_adapters`.
    fn prepareAdapter(
        self: *Registry,
        entry: shared.GlowcapTransportProviderEntry,
        profile: model.transport.Metadata,
        implementation: *const anyopaque,
        prior_entries: []const PreparedEntry,
        owned_adapters: []Adapter,
        owned: *usize,
    ) !Adapter {
        if (entry.execution_model == shared.transport_provider.GLOWCAP_TRANSPORT_EXEC_STREAM) {
            const table = try validation.implementationTable(shared.GlowcapStreamTransport, implementation, "stream");
            const adapter = try stream_adapter.prepare(&self.owner, profile, table);
            owned_adapters[owned.*] = .{ .stream = adapter };
            owned.* += 1;
            return .{ .stream = adapter };
        }
        for (prior_entries) |prior| {
            if (prior.implementation == implementation) return prior.adapter;
        }
        const table = try validation.implementationTable(shared.GlowcapMultiplexedTransport, implementation, "multiplexed");
        const adapter = try multiplexed_adapter.prepare(&self.owner, table);
        owned_adapters[owned.*] = .{ .multiplexed = adapter };
        owned.* += 1;
        return .{ .multiplexed = adapter };
    }
};

/// Check one entry's execution model and implementation table, alone and
/// against the entries before it. A stream profile owns its own table, and
/// one table uses one execution model. Nothing is built.
fn validateEntry(
    entry: shared.GlowcapTransportProviderEntry,
    prior_entries: []const shared.GlowcapTransportProviderEntry,
) !void {
    const exec = shared.transport_provider;
    const implementation = entry.implementation orelse {
        shared.setLastError("driver: provider entry has no implementation table", .{});
        return error.InvalidProviderPackage;
    };
    const stream = switch (entry.execution_model) {
        exec.GLOWCAP_TRANSPORT_EXEC_STREAM => true,
        exec.GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED => false,
        else => {
            shared.setLastError("driver: provider entry has an unknown execution model", .{});
            return error.InvalidProviderPackage;
        },
    };
    for (prior_entries) |prior| {
        if (prior.implementation != entry.implementation) continue;
        if (prior.execution_model != entry.execution_model) {
            shared.setLastError("driver: one implementation table cannot use two execution models", .{});
            return error.InvalidProviderPackage;
        }
        if (stream) {
            shared.setLastError("driver: each stream profile requires its own implementation table", .{});
            return error.InvalidProviderPackage;
        }
    }
    if (stream) {
        try stream_adapter.validate(try validation.implementationTable(shared.GlowcapStreamTransport, implementation, "stream"));
    } else {
        _ = try multiplexed_adapter.validate(try validation.implementationTable(shared.GlowcapMultiplexedTransport, implementation, "multiplexed"));
    }
}

fn refusePackage(comptime message: []const u8) ProviderInstallOutcome {
    shared.setLastError(message, .{});
    return .fromError(error.InvalidProviderPackage);
}

fn errorOutcome(err: anyerror) ProviderInstallOutcome {
    if (err != error.InvalidArgument) shared.setLastError("driver provider: {s}", .{@errorName(err)});
    return .fromError(err);
}

const Adapter = union(enum) {
    stream: *stream_adapter.Adapter,
    multiplexed: *multiplexed_adapter.Adapter,

    fn registration(
        self: Adapter,
        profile: model.transport.Metadata,
    ) driver.HostRuntime.ProviderRegistration {
        return .{ .profile = profile, .resident = switch (self) {
            .stream => |adapter| adapter.multiplexedResident(),
            .multiplexed => |adapter| adapter.multiplexedResident(),
        } };
    }

    fn deinit(self: Adapter, owner: *Owner) ?driver.OperationFailure {
        switch (self) {
            .stream => |adapter| return adapter.deinit(),
            .multiplexed => |adapter| owner.allocator.destroy(adapter),
        }
        return null;
    }
};
