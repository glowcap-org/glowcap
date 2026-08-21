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
const stream_adapter = @import("provider_registry/stream.zig");
const multiplexed_adapter = @import("provider_registry/multiplexed.zig");
const validation = @import("provider_registry/validation.zig");
const driver_error = @import("error.zig");
const failure_output = @import("failure_output.zig");

const shared = @import("c_abi_shared");

const Owner = owner_mod.Owner;

const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;

pub const ProviderInstallOutcome = install_outcome.Outcome;

const PreparedPackage = struct {
    owner: *Owner,
    adapters: []Adapter,
    lease_ctx: ?*anyopaque,
    same_configuration: shared.transport_provider.PancakeTransportProviderSameConfigurationFn,
    release: shared.transport_provider.PancakeTransportReleaseFn,

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
        for (self.adapters) |adapter| adapter.deinit(owner);
        owner.allocator.free(self.adapters);
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.release(self.lease_ctx, &report);
        const failure = owner.providerCallbackFailure(code, report, "provider package release");
        owner.allocator.destroy(self);
        return failure;
    }
};

const PreparedEntry = struct {
    profile: model.transport.Metadata,
    adapter: Adapter,
    /// The provider table's address is multiplexed runtime identity within one
    /// package preparation. Only multiplexed entries may share it; the table is
    /// validated and copied once, then every profile points at that adapter.
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
        provider: ?*const shared.PancakeTransportProvider,
    ) ProviderInstallOutcome {
        const package = provider orelse
            return .fromCode(PANCAKE_ERR_NULL_POINTER, error.NullPointer);
        self.owner.runtime.checkApplicationAdmission() catch |err| return errorOutcome(err);
        if (package.abi_version != shared.transport_provider.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION or
            package.struct_size < @sizeOf(shared.PancakeTransportProvider) or
            package.entry_count == 0 or package.entries == null or
            package.same_configuration == null or package.retain == null or package.release == null)
        {
            shared.setLastError("driver: invalid transport provider package", .{});
            return .fromCode(PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidProviderPackage);
        }

        const entries = package.entries.?[0..package.entry_count];
        const decoded_profiles = self.owner.allocator.alloc(model.transport.Metadata, entries.len) catch
            return .fromError(error.OutOfMemory);
        defer self.owner.allocator.free(decoded_profiles);
        for (entries, decoded_profiles) |entry, *profile| {
            const profile_table = entry.profile orelse {
                shared.setLastError("driver: provider entry has no transport profile", .{});
                return .fromCode(PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidProviderPackage);
            };
            profile.* = validation.transportProfile(profile_table) catch |err| return errorOutcome(err);
        }

        var retain_report = shared.transport_provider.emptyProviderFailure();
        const retain_code = package.retain.?(package.lease_ctx, &retain_report);
        if (self.owner.providerCallbackFailure(retain_code, retain_report, "provider package retain")) |retain_failure| {
            var failure = retain_failure;
            // A success status commits the lease even when its contradictory
            // diagnostic makes the callback a contract failure. Retire that
            // lease before refusing registration.
            if (retain_code == PANCAKE_OK) {
                var release_report = shared.transport_provider.emptyProviderFailure();
                const release_code = package.release.?(package.lease_ctx, &release_report);
                if (self.owner.providerCallbackFailure(
                    release_code,
                    release_report,
                    "provider package retain rollback",
                )) |cleanup| failure.noteFailure(cleanup);
            }
            failure_output.setLastError("driver provider retain", failure);
            return .{ .result = driver_error.code(failure.kind), .failure = failure };
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
        package: *const shared.PancakeTransportProvider,
        entries: []const shared.PancakeTransportProviderEntry,
        decoded_profiles: []const model.transport.Metadata,
        lease_consumed: *bool,
    ) ProviderInstallOutcome {
        const prepared_entries = self.owner.allocator.alloc(PreparedEntry, entries.len) catch
            return .fromError(error.OutOfMemory);
        defer self.owner.allocator.free(prepared_entries);
        const owned_adapters = self.owner.allocator.alloc(Adapter, entries.len) catch
            return .fromError(error.OutOfMemory);
        defer self.owner.allocator.free(owned_adapters);
        var prepared: usize = 0;
        var owned: usize = 0;
        var published = false;
        defer if (!published) for (owned_adapters[0..owned]) |adapter| adapter.deinit(&self.owner);

        for (entries, prepared_entries, decoded_profiles) |entry, *prepared_entry, profile| {
            const implementation = entry.implementation orelse {
                shared.setLastError("driver: provider entry has no implementation table", .{});
                return .fromCode(PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidProviderPackage);
            };
            for (prepared_entries[0..prepared]) |prior| {
                if (prior.implementation != implementation) continue;
                const same_model = switch (prior.adapter) {
                    .stream => entry.execution_model == shared.transport_provider.PANCAKE_TRANSPORT_EXEC_STREAM,
                    .multiplexed => entry.execution_model == shared.transport_provider.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED,
                };
                if (!same_model) {
                    shared.setLastError("driver: one implementation table cannot use two execution models", .{});
                    return .fromCode(PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidProviderPackage);
                }
                if (entry.execution_model == shared.transport_provider.PANCAKE_TRANSPORT_EXEC_STREAM) {
                    shared.setLastError("driver: each stream profile requires its own implementation table", .{});
                    return .fromCode(PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidProviderPackage);
                }
            }

            const adapter: Adapter = switch (entry.execution_model) {
                shared.transport_provider.PANCAKE_TRANSPORT_EXEC_STREAM => blk: {
                    const table = validation.implementationTable(shared.PancakeStreamTransport, implementation, "stream") catch |err|
                        return errorOutcome(err);
                    const adapter = stream_adapter.prepare(&self.owner, profile, table) catch |err| return errorOutcome(err);
                    owned_adapters[owned] = .{ .stream = adapter };
                    owned += 1;
                    break :blk .{ .stream = adapter };
                },
                shared.transport_provider.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED => blk: {
                    for (prepared_entries[0..prepared]) |prior| {
                        if (prior.implementation == implementation) break :blk prior.adapter;
                    }
                    const table = validation.implementationTable(shared.PancakeMultiplexedTransport, implementation, "multiplexed") catch |err|
                        return errorOutcome(err);
                    const adapter = multiplexed_adapter.prepare(&self.owner, table) catch |err| return errorOutcome(err);
                    owned_adapters[owned] = .{ .multiplexed = adapter };
                    owned += 1;
                    break :blk .{ .multiplexed = adapter };
                },
                else => {
                    shared.setLastError("driver: provider entry has an unknown execution model", .{});
                    return .fromCode(PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidProviderPackage);
                },
            };
            prepared_entry.* = .{
                .profile = profile,
                .adapter = adapter,
                .implementation = implementation,
            };
            prepared += 1;
        }

        const registrations = self.owner.allocator.alloc(driver.HostRuntime.ProviderRegistration, entries.len) catch
            return .fromError(error.OutOfMemory);
        defer self.owner.allocator.free(registrations);
        const resident_indices = self.owner.allocator.alloc(?usize, entries.len) catch
            return .fromError(error.OutOfMemory);
        defer self.owner.allocator.free(resident_indices);
        for (prepared_entries, registrations) |entry, *registration| {
            registration.* = entry.registration();
        }

        const adapter_owners = self.owner.allocator.dupe(Adapter, owned_adapters[0..owned]) catch
            return .fromError(error.OutOfMemory);
        var adapter_owners_live = true;
        defer if (adapter_owners_live) self.owner.allocator.free(adapter_owners);
        const prepared_package = self.owner.allocator.create(PreparedPackage) catch
            return .fromError(error.OutOfMemory);
        prepared_package.* = .{
            .owner = &self.owner,
            .adapters = adapter_owners,
            .lease_ctx = package.lease_ctx,
            .same_configuration = package.same_configuration.?,
            .release = package.release.?,
        };
        adapter_owners_live = false;
        published = true;
        lease_consumed.* = true;
        const installed = self.owner.runtime.addProviderPackage(.{
            .registrations = registrations,
            .owner = .{
                .ctx = prepared_package,
                .same_configuration = PreparedPackage.sameConfiguration,
                .release = PreparedPackage.releaseOwner,
            },
        }, resident_indices) catch |err| {
            if (err == error.ProviderConfigurationConflict)
                shared.setLastError("driver: transport profiles are already owned by another provider configuration", .{});
            var failure = driver.OperationFailure.fromError(err);
            if (PreparedPackage.releaseOwner(prepared_package)) |cleanup| failure.noteFailure(cleanup);
            failure_output.setLastError("driver provider registration", failure);
            return .{ .result = driver_error.code(failure.kind), .failure = failure };
        };
        if (!installed) {
            if (PreparedPackage.releaseOwner(prepared_package)) |failure| {
                failure_output.setLastError("driver provider release", failure);
                return .{ .result = driver_error.code(failure.kind), .failure = failure };
            }
        }
        return .{};
    }
};

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
        return switch (self) {
            .stream => |adapter| .{ .stream = adapter.netlayer() },
            .multiplexed => |adapter| .{ .multiplexed = .{
                .profile = profile,
                .resident = adapter.multiplexedResident(),
            } },
        };
    }

    fn deinit(self: Adapter, owner: *Owner) void {
        switch (self) {
            .stream => |adapter| adapter.deinit(),
            .multiplexed => |adapter| owner.allocator.destroy(adapter),
        }
    }
};
