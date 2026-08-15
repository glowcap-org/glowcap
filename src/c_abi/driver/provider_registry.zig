//! Own the driver's generic transport-provider seam.
//!
//! This module validates provider packages, adapts their C execution tables to
//! `HostRuntime`'s Zig contracts, and holds every copied callback and package lease.
//! It knows stream and multiplexed execution models, but no concrete transport.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const net = @import("net");
const driver = @import("driver");
const provider_locator = @import("provider_locator.zig");
const driver_error = @import("error.zig");

const shared = @import("c_abi_shared");

const crypto = foundation.crypto;
const LocatorProjection = shared.locator_adapter.Projection;

const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;

fn projectOperationOptions(
    options: net.OperationOptions,
    storage: *shared.PancakeTransportOperationOptions,
) ?*const shared.PancakeTransportOperationOptions {
    const data = options.data orelse return null;
    storage.* = .{ .data = data, .size = options.size };
    return storage;
}

fn multiplexedIoResultValid(result: isize, capacity: usize) bool {
    if (result == -1 or result == shared.PANCAKE_MULTIPLEXED_WOULD_BLOCK) return true;
    if (result < 0) return false;
    return @as(usize, @intCast(result)) <= capacity;
}

const untouched_listen_state = std.math.maxInt(u32);

fn emptyListenResult() shared.PancakeListenResult {
    return .{
        .state = untouched_listen_state,
        .listener = null,
        .attempt = null,
        .readiness_fd = -1,
    };
}

fn listenResultUntouched(result: shared.PancakeListenResult) bool {
    return result.state == untouched_listen_state and
        result.listener == null and result.attempt == null and result.readiness_fd == -1;
}

const PreparedPackage = struct {
    registry: *Registry,
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
                installed.registry.failContract("same_configuration returned a value other than 0 or 1");
                return error.ProviderContract;
            },
        };
    }

    fn releaseOwner(raw: *anyopaque) ?driver.OperationFailure {
        const self: *PreparedPackage = @ptrCast(@alignCast(raw));
        const registry = self.registry;
        for (self.adapters) |adapter| adapter.deinit(registry);
        registry.allocator.free(self.adapters);
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.release(self.lease_ctx, &report);
        const failure = registry.providerCallbackFailure(code, report, "provider package release");
        registry.allocator.destroy(self);
        return failure;
    }
};

fn providerStatusError(code: i32) anyerror {
    return switch (code) {
        shared.PANCAKE_ERR_NULL_POINTER => error.ProviderNullPointer,
        shared.PANCAKE_ERR_INVALID_ARGUMENT => error.ProviderInvalidArgument,
        shared.PANCAKE_ERR_INTERNAL => error.ProviderInternal,
        shared.PANCAKE_ERR_WOULD_BLOCK => error.ProviderWouldBlock,
        shared.PANCAKE_ERR_CLOSED => error.ProviderClosed,
        shared.PANCAKE_ERR_TIMEOUT => error.ProviderTimedOut,
        shared.PANCAKE_ERR_SESSION => error.ProviderSession,
        shared.PANCAKE_ERR_MALFORMED => error.ProviderMalformed,
        shared.PANCAKE_ERR_FRAME_TOO_LARGE => error.ProviderFrameTooLarge,
        shared.PANCAKE_ERR_IO => error.ProviderIo,
        else => error.ProviderFailure,
    };
}

fn providerStatusClassification(code: i32) foundation.FailureClassification {
    return switch (code) {
        shared.PANCAKE_ERR_NULL_POINTER,
        shared.PANCAKE_ERR_INVALID_ARGUMENT,
        => .invalid_argument,
        shared.PANCAKE_ERR_INTERNAL => .internal,
        shared.PANCAKE_ERR_WOULD_BLOCK => .would_block,
        shared.PANCAKE_ERR_CLOSED => .closed,
        shared.PANCAKE_ERR_TIMEOUT => .timeout,
        shared.PANCAKE_ERR_SESSION => .session,
        shared.PANCAKE_ERR_MALFORMED => .malformed,
        shared.PANCAKE_ERR_FRAME_TOO_LARGE => .frame_too_large,
        shared.PANCAKE_ERR_IO => .io,
        else => unreachable,
    };
}

fn providerStatusIsStable(code: i32) bool {
    return switch (code) {
        shared.PANCAKE_ERR_NULL_POINTER,
        shared.PANCAKE_ERR_INVALID_ARGUMENT,
        shared.PANCAKE_ERR_INTERNAL,
        shared.PANCAKE_ERR_WOULD_BLOCK,
        shared.PANCAKE_ERR_CLOSED,
        shared.PANCAKE_ERR_TIMEOUT,
        shared.PANCAKE_ERR_SESSION,
        shared.PANCAKE_ERR_MALFORMED,
        shared.PANCAKE_ERR_FRAME_TOO_LARGE,
        shared.PANCAKE_ERR_IO,
        => true,
        else => false,
    };
}

fn providerFailureName(pointer: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0 or pointer == null) return null;
    const name = pointer.?[0..len];
    if (!std.unicode.utf8ValidateSlice(name)) return null;
    return name;
}

fn operationFailureFromProvider(
    code: i32,
    report: shared.PancakeProviderFailure,
) error{InvalidProviderFailure}!driver.OperationFailure {
    const primary_name = providerFailureName(report.primary_name, report.primary_name_len);
    const secondary_name = providerFailureName(report.secondary_name, report.secondary_name_len);
    const valid_secondary = if (report.secondary_count == 0)
        report.secondary_result == 0 and report.secondary_name == null and report.secondary_name_len == 0
    else
        report.secondary_count <= std.math.maxInt(u16) and
            providerStatusIsStable(report.secondary_result) and secondary_name != null;
    if (report.result != code or !providerStatusIsStable(code) or primary_name == null or !valid_secondary)
        return error.InvalidProviderFailure;
    var failure = driver.OperationFailure.fromError(providerStatusError(code));
    failure.kind = driver.OperationFailure.fromClassification(providerStatusClassification(code));
    failure.namePrimary(primary_name.?);
    if (report.secondary_count != 0) {
        failure.noteNamed(providerStatusError(report.secondary_result), secondary_name.?);
        failure.secondary_kind = driver.OperationFailure.fromClassification(providerStatusClassification(report.secondary_result));
        failure.secondary_count = @intCast(report.secondary_count);
    }
    return failure;
}

fn failureChainFromProvider(
    code: i32,
    report: shared.PancakeProviderFailure,
) error{InvalidProviderFailure}!foundation.FailureChain {
    const failure = try operationFailureFromProvider(code, report);
    return .{
        .cause = failure.cause,
        .cause_name = failure.cause_name,
        .classification = providerStatusClassification(code),
        .secondary_cause = failure.secondary_cause,
        .secondary_cause_name = failure.secondary_cause_name,
        .secondary_classification = if (report.secondary_count != 0)
            providerStatusClassification(report.secondary_result)
        else
            null,
        .secondary_count = failure.secondary_count,
    };
}

fn providerFailureIsEmpty(report: shared.PancakeProviderFailure) bool {
    return shared.transport_provider.providerFailureEmpty(report);
}

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
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *driver.HostRuntime,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, runtime: *driver.HostRuntime) Registry {
        return .{ .allocator = allocator, .io = io, .runtime = runtime };
    }

    pub fn deinit(self: *Registry) void {
        self.* = undefined;
    }

    fn failContract(self: *Registry, message: []const u8) void {
        self.runtime.failProviderContract();
        shared.setLastError("driver: transport provider contract violation: {s}", .{message});
    }

    fn providerCallbackFailure(
        self: *Registry,
        code: i32,
        report: shared.PancakeProviderFailure,
        operation: []const u8,
    ) ?driver.OperationFailure {
        if (code == PANCAKE_OK) {
            if (providerFailureIsEmpty(report)) return null;
            self.failContract("provider callback reported failure data on success");
            return driver.OperationFailure.fromError(error.ProviderContract);
        }
        return operationFailureFromProvider(code, report) catch {
            self.failContract("provider callback returned an invalid structured failure");
            shared.setLastError("driver: invalid structured failure from {s}", .{operation});
            return driver.OperationFailure.fromError(error.ProviderContract);
        };
    }

    /// Install one package atomically. Every profile and implementation table
    /// is validated and allocated before HostRuntime publishes any registration.
    pub fn addProvider(
        self: *Registry,
        provider: ?*const shared.PancakeTransportProvider,
    ) i32 {
        const package = provider orelse return PANCAKE_ERR_NULL_POINTER;
        self.runtime.checkApplicationAdmission() catch |err| return errToCode(err);
        if (package.abi_version != shared.transport_provider.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION or
            package.struct_size < @sizeOf(shared.PancakeTransportProvider) or
            package.entry_count == 0 or package.entries == null or
            package.same_configuration == null or package.retain == null or package.release == null)
        {
            shared.setLastError("driver: invalid transport provider package", .{});
            return PANCAKE_ERR_INVALID_ARGUMENT;
        }

        const entries = package.entries.?[0..package.entry_count];
        const decoded_profiles = self.allocator.alloc(model.transport.Metadata, entries.len) catch
            return shared.PANCAKE_ERR_INTERNAL;
        defer self.allocator.free(decoded_profiles);
        for (entries, decoded_profiles) |entry, *profile| {
            const profile_table = entry.profile orelse {
                shared.setLastError("driver: provider entry has no transport profile", .{});
                return PANCAKE_ERR_INVALID_ARGUMENT;
            };
            profile.* = decodeTransportProfile(profile_table) catch |err| return errToCode(err);
        }

        var retain_report = shared.transport_provider.emptyProviderFailure();
        const retain_code = package.retain.?(package.lease_ctx, &retain_report);
        if (self.providerCallbackFailure(retain_code, retain_report, "provider package retain")) |retain_failure| {
            var failure = retain_failure;
            // A success status commits the lease even when its contradictory
            // diagnostic makes the callback a contract failure. Retire that
            // lease before refusing registration.
            if (retain_code == PANCAKE_OK) {
                var release_report = shared.transport_provider.emptyProviderFailure();
                const release_code = package.release.?(package.lease_ctx, &release_report);
                if (self.providerCallbackFailure(
                    release_code,
                    release_report,
                    "provider package retain rollback",
                )) |cleanup| failure.noteFailure(cleanup);
            }
            setProviderFailure("driver provider retain", failure);
            return driver_error.code(failure.kind);
        }

        var lease_consumed = false;
        const result = self.addRetainedProvider(package, entries, decoded_profiles, &lease_consumed);
        if (lease_consumed) return result;
        var release_report = shared.transport_provider.emptyProviderFailure();
        const release_code = package.release.?(package.lease_ctx, &release_report);
        return retainReleaseOutcome(result, self.providerCallbackFailure(
            release_code,
            release_report,
            "provider package rollback release",
        ));
    }

    fn addRetainedProvider(
        self: *Registry,
        package: *const shared.PancakeTransportProvider,
        entries: []const shared.PancakeTransportProviderEntry,
        decoded_profiles: []const model.transport.Metadata,
        lease_consumed: *bool,
    ) i32 {
        const prepared_entries = self.allocator.alloc(PreparedEntry, entries.len) catch
            return shared.PANCAKE_ERR_INTERNAL;
        defer self.allocator.free(prepared_entries);
        const owned_adapters = self.allocator.alloc(Adapter, entries.len) catch
            return shared.PANCAKE_ERR_INTERNAL;
        defer self.allocator.free(owned_adapters);
        var prepared: usize = 0;
        var owned: usize = 0;
        var published = false;
        defer if (!published) for (owned_adapters[0..owned]) |adapter| adapter.deinit(self);

        for (entries, prepared_entries, decoded_profiles) |entry, *prepared_entry, profile| {
            const implementation = entry.implementation orelse {
                shared.setLastError("driver: provider entry has no implementation table", .{});
                return PANCAKE_ERR_INVALID_ARGUMENT;
            };
            for (prepared_entries[0..prepared]) |prior| {
                if (prior.implementation != implementation) continue;
                const same_model = switch (prior.adapter) {
                    .stream => entry.execution_model == shared.transport_provider.PANCAKE_TRANSPORT_EXEC_STREAM,
                    .multiplexed => entry.execution_model == shared.transport_provider.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED,
                };
                if (!same_model) {
                    shared.setLastError("driver: one implementation table cannot use two execution models", .{});
                    return PANCAKE_ERR_INVALID_ARGUMENT;
                }
                if (entry.execution_model == shared.transport_provider.PANCAKE_TRANSPORT_EXEC_STREAM) {
                    shared.setLastError("driver: each stream profile requires its own implementation table", .{});
                    return PANCAKE_ERR_INVALID_ARGUMENT;
                }
            }

            const adapter: Adapter = switch (entry.execution_model) {
                shared.transport_provider.PANCAKE_TRANSPORT_EXEC_STREAM => blk: {
                    const table = implementationTable(shared.PancakeStreamTransport, implementation, "stream") catch |err|
                        return errToCode(err);
                    const adapter = prepareStreamAdapter(self, profile, table) catch |err| return errToCode(err);
                    owned_adapters[owned] = .{ .stream = adapter };
                    owned += 1;
                    break :blk .{ .stream = adapter };
                },
                shared.transport_provider.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED => blk: {
                    for (prepared_entries[0..prepared]) |prior| {
                        if (prior.implementation == implementation) break :blk prior.adapter;
                    }
                    const table = implementationTable(shared.PancakeMultiplexedTransport, implementation, "multiplexed") catch |err|
                        return errToCode(err);
                    const adapter = prepareMultiplexedAdapter(self, table) catch |err| return errToCode(err);
                    owned_adapters[owned] = .{ .multiplexed = adapter };
                    owned += 1;
                    break :blk .{ .multiplexed = adapter };
                },
                else => {
                    shared.setLastError("driver: provider entry has an unknown execution model", .{});
                    return PANCAKE_ERR_INVALID_ARGUMENT;
                },
            };
            prepared_entry.* = .{
                .profile = profile,
                .adapter = adapter,
                .implementation = implementation,
            };
            prepared += 1;
        }

        const registrations = self.allocator.alloc(driver.HostRuntime.ProviderRegistration, entries.len) catch
            return shared.PANCAKE_ERR_INTERNAL;
        defer self.allocator.free(registrations);
        const resident_indices = self.allocator.alloc(?usize, entries.len) catch
            return shared.PANCAKE_ERR_INTERNAL;
        defer self.allocator.free(resident_indices);
        for (prepared_entries, registrations) |entry, *registration| {
            registration.* = entry.registration();
        }

        const adapter_owners = self.allocator.dupe(Adapter, owned_adapters[0..owned]) catch
            return shared.PANCAKE_ERR_INTERNAL;
        var adapter_owners_live = true;
        defer if (adapter_owners_live) self.allocator.free(adapter_owners);
        const prepared_package = self.allocator.create(PreparedPackage) catch
            return shared.PANCAKE_ERR_INTERNAL;
        prepared_package.* = .{
            .registry = self,
            .adapters = adapter_owners,
            .lease_ctx = package.lease_ctx,
            .same_configuration = package.same_configuration.?,
            .release = package.release.?,
        };
        adapter_owners_live = false;
        published = true;
        lease_consumed.* = true;
        const installed = self.runtime.addProviderPackage(.{
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
            setProviderFailure("driver provider registration", failure);
            return driver_error.code(failure.kind);
        };
        if (!installed) {
            if (PreparedPackage.releaseOwner(prepared_package)) |failure| {
                setProviderFailure("driver provider release", failure);
                return driver_error.code(failure.kind);
            }
        }
        return PANCAKE_OK;
    }
};

fn retainReleaseOutcome(primary_code: i32, release_failure: ?driver.OperationFailure) i32 {
    const cleanup = release_failure orelse return primary_code;
    if (primary_code == PANCAKE_OK) {
        setProviderFailure("driver provider release", cleanup);
        return driver_error.code(cleanup.kind);
    }

    var primary: [256]u8 = undefined;
    const reported_len = shared.lastErrorRead(&primary, primary.len);
    const primary_len = @min(reported_len, primary.len - 1);
    if (primary_len == 0) {
        shared.setLastError("driver provider registration failed with status {d}; cleanup release failed: {s}", .{
            primary_code,
            cleanup.primaryName(),
        });
    } else {
        shared.setLastError("{s}; cleanup release failed: {s}", .{ primary[0..primary_len], cleanup.primaryName() });
    }
    return primary_code;
}

fn setProviderFailure(prefix: []const u8, failure: driver.OperationFailure) void {
    if (failure.secondary_cause) |_| {
        shared.setLastError("{s}: {s}; cleanup: {s} ({d} secondary failures)", .{
            prefix,
            failure.primaryName(),
            failure.secondaryName().?,
            failure.secondary_count,
        });
    } else {
        shared.setLastError("{s}: {s}", .{ prefix, failure.primaryName() });
    }
}

fn errToCode(err: anyerror) i32 {
    if (err != error.InvalidArgument) shared.setLastError("driver provider: {s}", .{@errorName(err)});
    return driver_error.fromError(err);
}

fn dialErrorFromCode(code: i32) net.netlayer.DialError {
    return switch (code) {
        shared.PANCAKE_ERR_INVALID_ARGUMENT => error.InvalidAddress,
        shared.PANCAKE_ERR_TIMEOUT => error.TimedOut,
        shared.PANCAKE_ERR_INTERNAL => error.OutOfMemory,
        else => error.ConnectionLost,
    };
}

fn validateOperationGroup(any: bool, complete: bool, kind: []const u8) !bool {
    if (any != complete) {
        shared.setLastError("driver: provider has a partial {s} operation group", .{kind});
        return error.InvalidArgument;
    }
    return complete;
}

fn implementationTable(comptime T: type, raw: *const anyopaque, kind: []const u8) !*const T {
    if (@intFromPtr(raw) % @alignOf(T) != 0) {
        shared.setLastError("driver: {s} provider table is misaligned", .{kind});
        return error.InvalidArgument;
    }
    return @ptrCast(@alignCast(raw));
}

fn validateTablePrefix(comptime T: type, table: *const T, version: u32, kind: []const u8) !void {
    if (table.abi_version != version or table.struct_size < @sizeOf(T)) {
        shared.setLastError("driver: {s} provider has an unsupported ABI", .{kind});
        return error.InvalidArgument;
    }
}

fn ownProfile(registry: *Registry, profile: model.transport.Metadata) !model.transport.Metadata {
    var owned = profile;
    owned.symbol = try registry.allocator.dupe(u8, profile.symbol);
    return owned;
}

fn destroyAdapter(registry: *Registry, adapter: anytype) void {
    registry.allocator.free(adapter.transport);
    registry.allocator.destroy(adapter);
}

// ── Foreign stream adapter ──────────────────────────────────────────────────

const StreamAdapter = struct {
    owner: *Registry,
    table: shared.PancakeStreamTransport,
    transport: []const u8,
    netlayer_vtable: net.netlayer.Netlayer.VTable,
    listener_vtable: net.netlayer.Listener.VTable,

    const Source = struct {
        adapter: *StreamAdapter,
        conn: *anyopaque,

        pub fn readSome(self: Source, dest: []u8) std.Io.Reader.Error!usize {
            const got = self.adapter.table.read.?(
                self.adapter.table.ctx,
                self.conn,
                dest.ptr,
                dest.len,
            );
            if (got == 0) return error.EndOfStream;
            if (got < 0) return error.ReadFailed;
            if (@as(usize, @intCast(got)) > dest.len) {
                self.adapter.owner.failContract("stream read returned more bytes than its capacity");
                return error.ReadFailed;
            }
            return @intCast(got);
        }

        pub fn writeAll(self: Source, bytes: []const u8) std.Io.Writer.Error!void {
            if (self.adapter.table.write_all.?(
                self.adapter.table.ctx,
                self.conn,
                bytes.ptr,
                bytes.len,
            ) != PANCAKE_OK) return error.WriteFailed;
        }

        pub fn flush(_: Source) std.Io.Writer.Error!void {}
    };

    const ConnContext = struct {
        adapter: *StreamAdapter,
        conn: *anyopaque,
        fd: i32,

        pub fn closeStream(self: ConnContext) void {
            if (self.adapter.closeConnection(self.conn)) |failure|
                self.adapter.owner.runtime.noteTerminalOperationFailure(failure);
        }

        pub fn socketHandle(self: ConnContext) ?std.Io.net.Socket.Handle {
            return self.fd;
        }

        pub fn takeFailure(self: ConnContext) ?foundation.FailureChain {
            var report = std.mem.zeroes(shared.PancakeProviderFailure);
            self.adapter.table.conn_take_failure.?(self.adapter.table.ctx, self.conn, &report);
            if (providerFailureIsEmpty(report)) return null;
            return failureChainFromProvider(report.result, report) catch {
                self.adapter.owner.failContract("stream conn_take_failure returned an invalid report");
                return foundation.FailureChain.init(error.ProviderContract);
            };
        }
    };

    const ForeignStream = net.netlayer.PinnedStream(Source, ConnContext);

    const ListenerBox = struct {
        adapter: *StreamAdapter,
        handle: *anyopaque,
    };

    fn netlayer(self: *StreamAdapter) net.netlayer.Netlayer {
        return .{ .ctx = self, .vtable = &self.netlayer_vtable };
    }

    fn of(ctx: *anyopaque) *StreamAdapter {
        return @ptrCast(@alignCast(ctx));
    }

    fn mapDialError(code: i32) net.netlayer.DialError {
        return dialErrorFromCode(code);
    }

    fn makeConnection(
        self: *StreamAdapter,
        peer: *engine.Peer,
        bufs: net.netlayer.Buffers,
        handle: *anyopaque,
        fd: i32,
    ) net.netlayer.DialError!net.Connection {
        const source: Source = .{ .adapter = self, .conn = handle };
        const stream = ForeignStream.create(peer.allocator, source, source, bufs, .{
            .adapter = self,
            .conn = handle,
            .fd = fd,
        }) catch |err| {
            var failure = driver.OperationFailure.fromError(err);
            if (self.closeConnection(handle)) |cleanup| failure.noteFailure(cleanup);
            self.owner.runtime.noteTerminalOperationFailure(failure);
            return err;
        };
        return stream.intoConnection(self.owner.io, peer);
    }

    fn closeConnection(self: *StreamAdapter, handle: *anyopaque) ?driver.OperationFailure {
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.conn_close.?(self.table.ctx, handle, &report);
        if (code == PANCAKE_OK) {
            if (providerFailureIsEmpty(report)) return null;
            self.owner.failContract("stream close reported failure data on success");
            return driver.OperationFailure.fromError(error.ProviderContract);
        }
        return operationFailureFromProvider(code, report) catch {
            self.owner.failContract("stream close returned an invalid structured failure");
            return driver.OperationFailure.fromError(error.ProviderContract);
        };
    }

    fn startDial(
        ctx: *anyopaque,
        locator: model.PeerLocator,
        options: net.OperationOptions,
    ) net.netlayer.DialStartOutcome {
        const self = of(ctx);
        var attempt: ?*anyopaque = null;
        var fd: i32 = -1;
        var hint_stack: [shared.locator_adapter.inline_hint_capacity]shared.PancakeLocatorHintView = undefined;
        var projection = LocatorProjection.init(self.owner.allocator, locator, &hint_stack) catch |err|
            return .{ .failed = .fromChain(
                if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidAddress,
                .init(err),
            ) };
        defer projection.deinit(self.owner.allocator);
        var options_storage: shared.PancakeTransportOperationOptions = undefined;
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.start_connect.?(
            self.table.ctx,
            &projection.view,
            projectOperationOptions(options, &options_storage),
            &attempt,
            &fd,
            &report,
        );
        if (code != PANCAKE_OK) {
            if (attempt != null or fd != -1)
                self.owner.failContract("stream connect start published outputs on failure");
            const chain = failureChainFromProvider(code, report) catch {
                self.owner.failContract("stream connect start returned an invalid structured failure");
                return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
            };
            return .{ .failed = .fromChain(mapDialError(code), chain) };
        }
        if (!providerFailureIsEmpty(report)) {
            self.owner.failContract("stream connect start reported failure data on success");
            if (attempt) |handle| if (self.cancelDialHandle(handle)) |cleanup|
                self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
            return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
        }
        const handle = attempt orelse {
            self.owner.failContract("stream connect start succeeded without an attempt handle");
            return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
        };
        if (fd < 0) {
            if (self.cancelDialHandle(handle)) |cleanup|
                self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
            self.owner.failContract("stream connect start succeeded without a readiness descriptor");
            return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
        }
        return .{ .admitted = .{
            .owner = self,
            .attempt = handle,
            .vtable = &dial_attempt_vtable,
            .readiness_fd = fd,
        } };
    }

    const dial_attempt_vtable = net.netlayer.DialAttempt.VTable{
        .finish = finishDial,
        .cancel = cancelDial,
    };

    fn finishDial(
        owner: *anyopaque,
        attempt: *anyopaque,
        peer: *engine.Peer,
        bufs: net.netlayer.Buffers,
    ) net.netlayer.DialFinishOutcome {
        const self = of(owner);
        var handle: ?*anyopaque = null;
        var fd: i32 = -1;
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.finish_connect.?(
            attempt,
            &handle,
            &fd,
            &report,
        );
        if (code != PANCAKE_OK) {
            if (handle != null or fd != -1)
                self.owner.failContract("stream connect finish published outputs on failure");
            const chain = failureChainFromProvider(code, report) catch {
                self.owner.failContract("stream connect finish returned an invalid structured failure");
                return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
            };
            return .{ .failed = .fromChain(mapDialError(code), chain) };
        }
        if (!providerFailureIsEmpty(report)) {
            self.owner.failContract("stream connect finish reported failure data on success");
            if (handle) |conn| if (self.closeConnection(conn)) |cleanup|
                self.owner.runtime.noteTerminalOperationFailure(cleanup);
            return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
        }
        const conn = handle orelse {
            self.owner.failContract("stream connect finish succeeded without a connection handle");
            return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
        };
        if (fd < 0) {
            self.owner.failContract("stream connect finish succeeded without a readiness descriptor");
            if (self.closeConnection(conn)) |cleanup|
                self.owner.runtime.noteTerminalOperationFailure(cleanup);
            return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
        }
        const connection = self.makeConnection(peer, bufs, conn, fd) catch |err|
            return .{ .failed = .init(err) };
        return .{ .connected = connection };
    }

    fn cancelDial(owner: *anyopaque, attempt: *anyopaque) ?foundation.FailureChain {
        const self = of(owner);
        return self.callStreamCancel(self.table.cancel_connect.?, attempt, "stream cancel_connect");
    }

    fn cancelDialHandle(self: *StreamAdapter, attempt: *anyopaque) ?foundation.FailureChain {
        return self.callStreamCancel(self.table.cancel_connect.?, attempt, "stream cancel_connect");
    }

    fn callStreamCancel(
        self: *StreamAdapter,
        callback: anytype,
        attempt: *anyopaque,
        operation: []const u8,
    ) ?foundation.FailureChain {
        var report = shared.transport_provider.emptyProviderFailure();
        const code = callback(attempt, &report);
        if (code == PANCAKE_OK) {
            if (providerFailureIsEmpty(report)) return null;
        } else if (!providerFailureIsEmpty(report)) {
            return failureChainFromProvider(code, report) catch {
                self.owner.failContract(operation);
                return foundation.FailureChain.init(error.ProviderContract);
            };
        }
        self.owner.failContract(operation);
        return foundation.FailureChain.init(error.ProviderContract);
    }

    fn closeListenerHandle(self: *StreamAdapter, handle: *anyopaque) ?net.netlayer.ListenerCloseFailure {
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.listener_close.?(self.table.ctx, handle, &report);
        if (code == PANCAKE_OK) {
            if (providerFailureIsEmpty(report)) return null;
            self.owner.failContract("stream listener close reported failure data on success");
            return .init(error.ProviderContract);
        }
        return failureChainFromProvider(code, report) catch {
            self.owner.failContract("stream listener close returned an invalid structured failure");
            return .init(error.ProviderContract);
        };
    }

    fn makeListener(
        self: *StreamAdapter,
        allocator: std.mem.Allocator,
        handle: *anyopaque,
    ) net.netlayer.ListenFinishOutcome {
        const box = allocator.create(ListenerBox) catch |err| {
            var failure = net.netlayer.ListenFailure.init(err);
            if (self.closeListenerHandle(handle)) |cleanup| failure.noteChain(cleanup);
            return .{ .failed = failure };
        };
        box.* = .{ .adapter = self, .handle = handle };
        return .{ .ready = .{ .ctx = box, .vtable = &self.listener_vtable } };
    }

    fn listen(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        config: net.netlayer.ListenConfig,
    ) net.netlayer.ListenStartOutcome {
        const self = of(ctx);
        var identity_storage: [crypto.PeerKey.designator_len]u8 = undefined;
        const identity: []const u8 = if (config.identity) |key| blk: {
            identity_storage = key.toDesignator();
            break :blk &identity_storage;
        } else &.{};
        var result = emptyListenResult();
        var report = shared.transport_provider.emptyProviderFailure();
        var options_storage: shared.PancakeTransportOperationOptions = undefined;
        const code = self.table.listen.?(
            self.table.ctx,
            config.designator.ptr,
            config.designator.len,
            identity.ptr,
            identity.len,
            projectOperationOptions(config.options, &options_storage),
            &result,
            &report,
        );
        if (code == PANCAKE_OK and !providerFailureIsEmpty(report)) {
            var failure = net.netlayer.ListenFailure.init(error.ProviderContract);
            if (result.listener) |listener| {
                if (self.closeListenerHandle(listener)) |cleanup| failure.noteChain(cleanup);
            }
            if (result.attempt) |attempt| if (self.cancelListenHandle(attempt)) |cleanup| failure.noteChain(cleanup);
            self.owner.failContract("stream listen reported failure data on success");
            return .{ .failed = failure };
        }
        if (code != PANCAKE_OK) {
            var failure = failureChainFromProvider(code, report) catch blk: {
                self.owner.failContract("stream listen returned an invalid structured failure");
                break :blk net.netlayer.ListenFailure.init(error.ProviderContract);
            };
            if (result.listener) |listener| {
                if (self.closeListenerHandle(listener)) |cleanup| failure.noteChain(cleanup);
            }
            if (result.attempt) |attempt| if (self.cancelListenHandle(attempt)) |cleanup| failure.noteChain(cleanup);
            if (!listenResultUntouched(result))
                self.owner.failContract("stream listen published outputs on failure");
            return .{ .failed = failure };
        }
        return switch (result.state) {
            shared.PANCAKE_LISTEN_READY => blk: {
                const listener = result.listener orelse {
                    var failure = net.netlayer.ListenFailure.init(error.BindFailed);
                    if (result.attempt) |attempt| {
                        if (self.cancelListenHandle(attempt)) |cleanup| failure.noteChain(cleanup);
                    }
                    self.owner.failContract("ready stream listen returned no listener");
                    return .{ .failed = failure };
                };
                if (result.attempt != null or result.readiness_fd != -1) {
                    var failure = net.netlayer.ListenFailure.init(error.BindFailed);
                    if (self.closeListenerHandle(listener)) |cleanup| failure.noteChain(cleanup);
                    if (result.attempt) |attempt| {
                        if (self.cancelListenHandle(attempt)) |cleanup| failure.noteChain(cleanup);
                    }
                    self.owner.failContract("ready stream listener returned pending-operation fields");
                    return .{ .failed = failure };
                }
                break :blk switch (self.makeListener(allocator, listener)) {
                    .ready => |ready| .{ .admitted = .{ .ready = ready } },
                    .failed => |failure| .{ .failed = failure },
                };
            },
            shared.PANCAKE_LISTEN_PENDING => blk: {
                const attempt = result.attempt orelse {
                    var failure = net.netlayer.ListenFailure.init(error.BindFailed);
                    if (result.listener) |listener| {
                        if (self.closeListenerHandle(listener)) |cleanup| failure.noteChain(cleanup);
                    }
                    self.owner.failContract("pending stream listener returned no attempt");
                    return .{ .failed = failure };
                };
                if (result.listener != null or result.readiness_fd < 0 or
                    self.table.finish_listen == null or self.table.cancel_listen == null)
                {
                    var failure = net.netlayer.ListenFailure.init(error.BindFailed);
                    if (result.listener) |listener| {
                        if (self.closeListenerHandle(listener)) |cleanup| failure.noteChain(cleanup);
                    }
                    if (self.cancelListenHandle(attempt)) |cleanup| failure.noteChain(cleanup);
                    self.owner.failContract("pending stream listener returned an incomplete attempt");
                    return .{ .failed = failure };
                }
                break :blk .{ .admitted = .{ .pending = .{
                    .owner = self,
                    .attempt = attempt,
                    .finish_fn = finishListen,
                    .cancel_fn = cancelListen,
                    .readiness_fd = result.readiness_fd,
                } } };
            },
            else => {
                var failure = net.netlayer.ListenFailure.init(error.BindFailed);
                if (result.listener) |listener| {
                    if (self.closeListenerHandle(listener)) |cleanup| failure.noteChain(cleanup);
                }
                if (result.attempt) |attempt| if (self.cancelListenHandle(attempt)) |cleanup| failure.noteChain(cleanup);
                self.owner.failContract("stream listen returned an unknown result state");
                return .{ .failed = failure };
            },
        };
    }

    fn finishListen(
        owner: *anyopaque,
        attempt: *anyopaque,
        allocator: std.mem.Allocator,
    ) net.netlayer.ListenFinishOutcome {
        const self = of(owner);
        var handle: ?*anyopaque = null;
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.finish_listen.?(attempt, &handle, &report);
        if (code == PANCAKE_OK and !providerFailureIsEmpty(report)) {
            var failure = net.netlayer.ListenFailure.init(error.ProviderContract);
            if (handle) |listener| {
                if (self.closeListenerHandle(listener)) |cleanup| failure.noteChain(cleanup);
            }
            self.owner.failContract("stream listener finish reported failure data on success");
            return .{ .failed = failure };
        }
        if (code != PANCAKE_OK) {
            if (handle != null)
                self.owner.failContract("stream listener finish published an output on failure");
            const failure = failureChainFromProvider(code, report) catch blk: {
                self.owner.failContract("stream listener finish returned an invalid structured failure");
                break :blk net.netlayer.ListenFailure.init(error.ProviderContract);
            };
            return .{ .failed = failure };
        }
        const listener_handle = handle orelse {
            self.owner.failContract("stream listener finish succeeded without a listener handle");
            return .{ .failed = .init(error.BindFailed) };
        };
        return self.makeListener(allocator, listener_handle);
    }

    fn cancelListen(owner: *anyopaque, attempt: *anyopaque) ?net.netlayer.ListenerCloseFailure {
        const self = of(owner);
        return self.cancelListenHandle(attempt);
    }

    fn cancelListenHandle(self: *StreamAdapter, attempt: *anyopaque) ?foundation.FailureChain {
        const cancel = self.table.cancel_listen orelse return null;
        return self.callStreamCancel(cancel, attempt, "stream cancel_listen");
    }

    fn listenerOf(ctx: *anyopaque) *ListenerBox {
        return @ptrCast(@alignCast(ctx));
    }

    fn acceptClassification(code: i32) net.netlayer.AcceptError {
        return switch (code) {
            shared.PANCAKE_ERR_INTERNAL => error.OutOfMemory,
            else => error.ConnectionLost,
        };
    }

    fn listenerAcceptDetailed(ctx: *anyopaque, peer: *engine.Peer, bufs: net.netlayer.Buffers) net.netlayer.AcceptOutcome {
        const box = listenerOf(ctx);
        var handle: ?*anyopaque = null;
        var fd: i32 = -1;
        var report = std.mem.zeroes(shared.PancakeProviderFailure);
        const code = box.adapter.table.accept.?(
            box.adapter.table.ctx,
            box.handle,
            &handle,
            &fd,
            &report,
        );
        if (code != PANCAKE_OK) {
            if (handle != null or fd != -1)
                box.adapter.owner.failContract("stream accept published outputs on failure");
            const chain = failureChainFromProvider(code, report) catch {
                box.adapter.owner.failContract("stream accept returned an invalid failure report");
                return .{ .failed = .init(error.ConnectionLost) };
            };
            return .{ .failed = .fromChain(acceptClassification(code), chain) };
        }
        if (!providerFailureIsEmpty(report)) {
            box.adapter.owner.failContract("stream accept reported failure on success");
            if (handle) |conn| if (box.adapter.closeConnection(conn)) |cleanup|
                box.adapter.owner.runtime.noteTerminalOperationFailure(cleanup);
            return .{ .failed = .init(error.ConnectionLost) };
        }
        const conn = handle orelse {
            box.adapter.owner.failContract("stream accept succeeded without a connection handle");
            return .{ .failed = .init(error.ConnectionLost) };
        };
        if (fd < 0) {
            box.adapter.owner.failContract("stream accept succeeded without a readiness descriptor");
            if (box.adapter.closeConnection(conn)) |cleanup|
                box.adapter.owner.runtime.noteTerminalOperationFailure(cleanup);
            return .{ .failed = .init(error.ConnectionLost) };
        }
        return .{ .accepted = box.adapter.makeConnection(peer, bufs, conn, fd) catch |err|
            return .{ .failed = .init(if (err == error.OutOfMemory) error.OutOfMemory else error.ConnectionLost) } };
    }

    fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: net.netlayer.Buffers) net.netlayer.AcceptError!net.Connection {
        return switch (listenerAcceptDetailed(ctx, peer, bufs)) {
            .accepted => |conn| conn,
            .failed => |failure| failure.classification,
        };
    }

    fn listenerWait(ctx: *anyopaque, timeout_ms: i32, callback: shared.transport_provider.PancakeStreamListenerWaitFn) net.netlayer.AcceptError!bool {
        return switch (listenerWaitDetailed(ctx, timeout_ms, callback)) {
            .ready => |ready| ready,
            .failed => |failure| failure.classification,
        };
    }

    fn listenerWaitDetailed(ctx: *anyopaque, timeout_ms: i32, callback: shared.transport_provider.PancakeStreamListenerWaitFn) net.netlayer.AcceptReadinessOutcome {
        const box = listenerOf(ctx);
        var report = std.mem.zeroes(shared.PancakeProviderFailure);
        const code = callback(box.adapter.table.ctx, box.handle, timeout_ms, &report);
        if (code == PANCAKE_OK or code == PANCAKE_ERR_WOULD_BLOCK) {
            if (!providerFailureIsEmpty(report)) {
                box.adapter.owner.failContract("stream listener wait reported failure on success");
                return .{ .failed = .init(error.ConnectionLost) };
            }
            return .{ .ready = code == PANCAKE_OK };
        }
        const chain = failureChainFromProvider(code, report) catch {
            box.adapter.owner.failContract("stream listener wait returned an invalid failure report");
            return .{ .failed = .init(error.ConnectionLost) };
        };
        return .{ .failed = .fromChain(acceptClassification(code), chain) };
    }

    fn listenerWaitAcceptable(ctx: *anyopaque, timeout_ms: i32) net.netlayer.AcceptError!bool {
        const box = listenerOf(ctx);
        return listenerWait(ctx, timeout_ms, box.adapter.table.listener_wait_acceptable.?);
    }

    fn listenerWaitAcceptableDetailed(ctx: *anyopaque, timeout_ms: i32) net.netlayer.AcceptReadinessOutcome {
        const box = listenerOf(ctx);
        return listenerWaitDetailed(ctx, timeout_ms, box.adapter.table.listener_wait_acceptable.?);
    }

    fn localLocator(ctx: *anyopaque, allocator: std.mem.Allocator) net.netlayer.ListenError!model.PeerLocator {
        const box = listenerOf(ctx);
        return (provider_locator.Listener{
            .ctx = box.handle,
            .transport = box.adapter.transport,
            .local = box.adapter.table.listener_locator.?,
            .canonicalize = box.adapter.table.listener_advertise.?,
        }).localLocator(allocator);
    }

    fn canonicalizeLocator(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) net.netlayer.ListenError!model.PeerLocator {
        const box = listenerOf(ctx);
        return (provider_locator.Listener{
            .ctx = box.handle,
            .transport = box.adapter.transport,
            .local = box.adapter.table.listener_locator.?,
            .canonicalize = box.adapter.table.listener_advertise.?,
        }).canonicalizeLocator(allocator, locator);
    }

    fn listenerRestorationState(ctx: *anyopaque, out: []u8) net.netlayer.RestorationStateError!usize {
        const box = listenerOf(ctx);
        var needed: usize = 0;
        const code = box.adapter.table.listener_restoration_state.?(
            box.handle,
            if (out.len == 0) null else out.ptr,
            out.len,
            &needed,
        );
        const valid = (code == PANCAKE_OK and needed <= out.len) or
            (code == shared.PANCAKE_ERR_BUFFER_TOO_SMALL and needed > out.len);
        if (!valid) {
            box.adapter.owner.failContract("stream listener returned an invalid restoration-state result");
            return error.ProviderFailure;
        }
        return needed;
    }

    fn listenerReadinessFd(ctx: *anyopaque) i32 {
        const box = listenerOf(ctx);
        const fd = box.adapter.table.listener_readiness_fd.?(
            box.adapter.table.ctx,
            box.handle,
        );
        if (fd < 0) box.adapter.owner.failContract("stream listener returned an invalid readiness descriptor");
        return fd;
    }

    fn listenerClose(ctx: *anyopaque) ?net.netlayer.ListenerCloseFailure {
        const box = listenerOf(ctx);
        const allocator = box.adapter.owner.allocator;
        const failure = box.adapter.closeListenerHandle(box.handle);
        allocator.destroy(box);
        return failure;
    }

    fn io(ctx: *anyopaque) ?std.Io {
        return of(ctx).owner.io;
    }
};

// ── Multiplexed-transport adapter ────────────────────────────────────────────

/// One C multiplexed runtime adapted back into the Zig `MultiplexedResident`
/// contract. Transport profile metadata belongs to provider entries, so one
/// adapter can realize several profiles through one readiness descriptor.
const MultiplexedAdapter = struct {
    owner: *Registry,
    table: shared.PancakeMultiplexedTransport,
    vtable: net.MultiplexedResident.VTable,

    fn multiplexedResident(self: *MultiplexedAdapter) net.MultiplexedResident {
        return .{ .ctx = self, .vtable = &self.vtable };
    }

    fn of(ctx: *anyopaque) *MultiplexedAdapter {
        return @ptrCast(@alignCast(ctx));
    }

    fn readinessFd(ctx: *anyopaque) i32 {
        const self = of(ctx);
        return self.table.readiness_fd.?(self.table.ctx);
    }

    fn drainReady(
        ctx: *anyopaque,
        out: []net.multiplexed_resident.ReadyEvent,
    ) net.multiplexed_resident.ContractError!usize {
        const self = of(ctx);
        var c_buf: [32]shared.PancakeMultiplexedReadyEvent = undefined;
        var total: usize = 0;
        while (total < out.len) {
            const cap = @min(out.len - total, c_buf.len);
            var got: usize = 0;
            var report = std.mem.zeroes(shared.PancakeProviderFailure);
            const code = self.table.drain_ready.?(self.table.ctx, &c_buf, cap, &got, &report);
            if (code != PANCAKE_OK) {
                const failure = operationFailureFromProvider(code, report) catch {
                    self.failContract("drain_ready returned an invalid structured failure");
                    return error.ProviderContract;
                };
                self.owner.runtime.noteTerminalOperationFailure(failure);
                return error.ProviderContract;
            }
            if (!providerFailureIsEmpty(report)) {
                self.failContract("drain_ready reported failure data on success");
                return error.ProviderContract;
            }
            if (got > cap) {
                self.failContract("drain_ready returned more records than its capacity");
                return error.ProviderContract;
            }
            const event_mask = net.multiplexed_resident.ev_readable |
                net.multiplexed_resident.ev_writable |
                net.multiplexed_resident.ev_closed |
                net.multiplexed_resident.ev_accept |
                net.multiplexed_resident.ev_connect |
                net.multiplexed_resident.ev_listen;
            for (c_buf[0..got], out[total .. total + got]) |src, *dst| {
                if (src.events == 0 or src.events & ~event_mask != 0) {
                    self.failContract("drain_ready returned an invalid event mask");
                    return error.ProviderContract;
                }
                if (src.events & net.multiplexed_resident.ev_accept != 0 and
                    src.events != net.multiplexed_resident.ev_accept)
                {
                    self.failContract("drain_ready combined accept with a connection event");
                    return error.ProviderContract;
                }
                if (src.events & net.multiplexed_resident.ev_connect != 0 and
                    src.events != net.multiplexed_resident.ev_connect)
                {
                    self.failContract("drain_ready combined connect with a connection event");
                    return error.ProviderContract;
                }
                if (src.events & net.multiplexed_resident.ev_listen != 0 and
                    src.events != net.multiplexed_resident.ev_listen)
                {
                    self.failContract("drain_ready combined listen with another event");
                    return error.ProviderContract;
                }
                if (src.events & net.multiplexed_resident.ev_accept != 0 and self.vtable.listen == null) {
                    self.failContract("dial-only resident emitted an accept event");
                    return error.ProviderContract;
                }
                if (src.events & net.multiplexed_resident.ev_listen != 0 and self.vtable.listen == null) {
                    self.failContract("non-listening resident emitted a listen event");
                    return error.ProviderContract;
                }
                if (src.events & net.multiplexed_resident.ev_connect != 0 and
                    self.vtable.dial == null and self.vtable.external_claim == null)
                {
                    self.failContract("resident emitted a connect event without a claim operation");
                    return error.ProviderContract;
                }
                const subject = std.math.cast(usize, src.subject) orelse {
                    self.failContract("drain_ready returned a subject outside the host id range");
                    return error.ProviderContract;
                };
                dst.* = .{ .subject = subject, .events = src.events };
                total += 1;
            }
            if (got < cap) break;
        }
        return total;
    }

    fn startConnect(
        ctx: *anyopaque,
        request_id: usize,
        locator: model.PeerLocator,
        options: net.OperationOptions,
    ) net.MultiplexedDialRawStartOutcome {
        const self = of(ctx);
        var hint_stack: [shared.locator_adapter.inline_hint_capacity]shared.PancakeLocatorHintView = undefined;
        var projection = LocatorProjection.init(self.owner.allocator, locator, &hint_stack) catch |err|
            return .{ .failed = .fromChain(
                if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidAddress,
                .init(err),
            ) };
        defer projection.deinit(self.owner.allocator);
        var options_storage: shared.PancakeTransportOperationOptions = undefined;
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.start_connect.?(
            self.table.ctx,
            @intCast(request_id),
            &projection.view,
            projectOperationOptions(options, &options_storage),
            &report,
        );
        if (code != PANCAKE_OK) {
            const chain = failureChainFromProvider(code, report) catch {
                self.failContract("multiplexed connect start returned an invalid structured failure");
                return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
            };
            return .{ .failed = .fromChain(dialErrorFromCode(code), chain) };
        }
        if (!providerFailureIsEmpty(report)) {
            self.failContract("multiplexed connect start reported failure data on success");
            if (self.callSubjectTeardown(self.table.cancel_connect.?, request_id, "cancel_connect")) |cleanup|
                self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
            return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
        }
        return .admitted;
    }

    fn finishConnect(ctx: *anyopaque, request_id: usize) net.MultiplexedDialRawFinishOutcome {
        const self = of(ctx);
        var conn: u64 = 0;
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.finish_connect.?(self.table.ctx, @intCast(request_id), &conn, &report);
        if (code != PANCAKE_OK) {
            if (conn != 0) self.failContract("finish_connect published an output on failure");
            const chain = failureChainFromProvider(code, report) catch {
                self.failContract("multiplexed connect finish returned an invalid structured failure");
                return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
            };
            return .{ .failed = .fromChain(dialErrorFromCode(code), chain) };
        }
        if (!providerFailureIsEmpty(report)) {
            self.failContract("multiplexed connect finish reported failure data on success");
            if (conn != 0) if (self.callSubjectTeardown(self.table.conn_close.?, @intCast(conn), "conn_close")) |cleanup|
                self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
            return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
        }
        const connection = std.math.cast(usize, conn) orelse {
            self.failContract("finish_connect returned a connection id outside the host range");
            return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
        };
        return .{ .connected = connection };
    }

    fn cancelConnect(ctx: *anyopaque, request_id: usize) ?foundation.FailureChain {
        const self = of(ctx);
        return self.callSubjectTeardown(self.table.cancel_connect.?, request_id, "cancel_connect");
    }

    fn claimExternal(ctx: *anyopaque, subject: usize) net.MultiplexedExternalClaimRawOutcome {
        const self = of(ctx);
        var conn: u64 = 0;
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.claim_external.?(self.table.ctx, @intCast(subject), &conn, &report);
        if (code == PANCAKE_OK and !providerFailureIsEmpty(report)) {
            self.failContract("claim_external reported failure data on success");
            if (conn != 0) if (self.callSubjectTeardown(self.table.conn_close.?, conn, "claim_external rollback")) |cleanup|
                self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
            return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
        }
        if (code != PANCAKE_OK) {
            if (conn != 0) self.failContract("claim_external published an output on failure");
            const chain = failureChainFromProvider(code, report) catch {
                self.failContract("claim_external returned an invalid structured failure");
                return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
            };
            return .{ .failed = .fromChain(dialErrorFromCode(code), chain) };
        }
        const connection = std.math.cast(usize, conn) orelse {
            self.failContract("claim_external returned a connection id outside the host range");
            return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
        };
        return .{ .claimed = connection };
    }

    fn listen(
        ctx: *anyopaque,
        route_id: usize,
        transport: []const u8,
        requested_designator: []const u8,
        options: net.OperationOptions,
    ) net.netlayer.ListenError!net.multiplexed_resident.RawListenResult {
        const self = of(ctx);
        var result = emptyListenResult();
        var options_storage: shared.PancakeTransportOperationOptions = undefined;
        const code = self.table.listen.?(
            self.table.ctx,
            @intCast(route_id),
            transport.ptr,
            transport.len,
            requested_designator.ptr,
            requested_designator.len,
            projectOperationOptions(options, &options_storage),
            &result,
        );
        if (code != PANCAKE_OK) {
            if (!listenResultUntouched(result))
                self.failContract("multiplexed listen published outputs on failure");
            return switch (code) {
                shared.PANCAKE_ERR_INVALID_ARGUMENT => error.InvalidAddress,
                shared.PANCAKE_ERR_INTERNAL => error.OutOfMemory,
                else => error.BindFailed,
            };
        }
        return switch (result.state) {
            shared.PANCAKE_LISTEN_READY => blk: {
                const listener = result.listener orelse {
                    if (self.table.cancel_listen) |cancel| if (self.callSubjectTeardown(cancel, route_id, "cancel_listen")) |cleanup|
                        self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                    self.failContract("ready multiplexed listen returned no listener");
                    return error.BindFailed;
                };
                if (result.attempt != null or result.readiness_fd != -1) {
                    if (self.callStopListen(listener)) |cleanup| self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                    self.failContract("ready multiplexed listen returned pending fields");
                    return error.BindFailed;
                }
                break :blk .{ .ready = listener };
            },
            shared.PANCAKE_LISTEN_PENDING => blk: {
                if (self.table.finish_listen == null or self.table.cancel_listen == null) {
                    if (result.listener) |listener| if (self.callStopListen(listener)) |cleanup|
                        self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                    self.failContract("immediate-only multiplexed listener returned pending");
                    return error.BindFailed;
                }
                if (result.listener != null or result.attempt != null or result.readiness_fd != -1) {
                    if (result.listener) |listener| if (self.callStopListen(listener)) |cleanup|
                        self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                    if (self.callSubjectTeardown(self.table.cancel_listen.?, route_id, "cancel_listen")) |cleanup|
                        self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                    self.failContract("pending multiplexed listen returned stream-owned fields");
                    return error.BindFailed;
                }
                break :blk .pending;
            },
            else => {
                if (result.listener) |listener| if (self.callStopListen(listener)) |cleanup|
                    self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                if (self.table.cancel_listen) |cancel| if (self.callSubjectTeardown(cancel, route_id, "cancel_listen")) |cleanup|
                    self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                self.failContract("multiplexed listen returned an unknown state");
                return error.BindFailed;
            },
        };
    }

    fn finishListen(ctx: *anyopaque, route_id: usize) net.netlayer.ListenError!*anyopaque {
        const self = of(ctx);
        var listener: ?*anyopaque = null;
        const code = self.table.finish_listen.?(self.table.ctx, @intCast(route_id), &listener);
        if (code != PANCAKE_OK) {
            if (listener != null)
                self.failContract("multiplexed listener finish published an output on failure");
            return switch (code) {
                shared.PANCAKE_ERR_INVALID_ARGUMENT => error.InvalidAddress,
                shared.PANCAKE_ERR_INTERNAL => error.OutOfMemory,
                else => error.BindFailed,
            };
        }
        return listener orelse {
            self.failContract("multiplexed listener finish returned no listener");
            return error.BindFailed;
        };
    }

    fn cancelListen(ctx: *anyopaque, route_id: usize) ?foundation.FailureChain {
        const self = of(ctx);
        return self.callSubjectTeardown(self.table.cancel_listen.?, route_id, "cancel_listen");
    }

    fn localLocator(
        ctx: *anyopaque,
        listener_ctx: *anyopaque,
        transport: []const u8,
        allocator: std.mem.Allocator,
    ) net.netlayer.ListenError!model.PeerLocator {
        const self = of(ctx);
        return (provider_locator.Listener{
            .ctx = listener_ctx,
            .transport = transport,
            .local = self.table.listener_locator.?,
            .canonicalize = self.table.listener_advertise.?,
        }).localLocator(allocator);
    }

    fn canonicalizeLocator(
        ctx: *anyopaque,
        listener_ctx: *anyopaque,
        transport: []const u8,
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) net.netlayer.ListenError!model.PeerLocator {
        const self = of(ctx);
        return (provider_locator.Listener{
            .ctx = listener_ctx,
            .transport = transport,
            .local = self.table.listener_locator.?,
            .canonicalize = self.table.listener_advertise.?,
        }).canonicalizeLocator(allocator, locator);
    }

    fn listenerRestorationState(
        ctx: *anyopaque,
        listener_ctx: *anyopaque,
        out: []u8,
    ) net.netlayer.RestorationStateError!usize {
        const self = of(ctx);
        var needed: usize = 0;
        const code = self.table.listener_restoration_state.?(
            listener_ctx,
            if (out.len == 0) null else out.ptr,
            out.len,
            &needed,
        );
        const valid = (code == PANCAKE_OK and needed <= out.len) or
            (code == shared.PANCAKE_ERR_BUFFER_TOO_SMALL and needed > out.len);
        if (!valid) {
            self.failContract("multiplexed listener returned an invalid restoration-state result");
            return error.ProviderFailure;
        }
        return needed;
    }

    fn finishAccept(ctx: *anyopaque, listener_ctx: *anyopaque) net.netlayer.AcceptError!?usize {
        return switch (finishAcceptDetailed(ctx, listener_ctx)) {
            .connection => |conn| conn,
            .failed => |failure| failure.classification,
        };
    }

    fn finishAcceptDetailed(ctx: *anyopaque, listener_ctx: *anyopaque) net.multiplexed_resident.MultiplexedResident.RawFinishAcceptOutcome {
        const self = of(ctx);
        var conn: u64 = 0;
        var report = std.mem.zeroes(shared.PancakeProviderFailure);
        const code = self.table.finish_accept.?(listener_ctx, &conn, &report);
        if (code != PANCAKE_OK and conn != 0) {
            self.failContract("finish_accept published an output on failure");
            return .{ .failed = .init(error.ConnectionLost) };
        }
        if (code == PANCAKE_OK or code == PANCAKE_ERR_WOULD_BLOCK) {
            if (!providerFailureIsEmpty(report)) {
                self.failContract("finish_accept reported failure on success");
                if (conn != 0) if (self.callSubjectTeardown(self.table.conn_close.?, @intCast(conn), "conn_close")) |cleanup|
                    self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                return .{ .failed = .init(error.ConnectionLost) };
            }
            if (code == PANCAKE_ERR_WOULD_BLOCK) return .{ .connection = null };
            return .{ .connection = std.math.cast(usize, conn) orelse {
                self.failContract("finish_accept returned a connection id outside the host range");
                return .{ .failed = .init(error.ConnectionLost) };
            } };
        }
        const chain = failureChainFromProvider(code, report) catch {
            self.failContract("finish_accept returned an invalid failure report");
            return .{ .failed = .init(error.ConnectionLost) };
        };
        const classification: net.netlayer.AcceptError = if (code == shared.PANCAKE_ERR_INTERNAL) error.OutOfMemory else error.ConnectionLost;
        return .{ .failed = .fromChain(classification, chain) };
    }

    fn stopListen(ctx: *anyopaque, listener_ctx: *anyopaque) ?foundation.FailureChain {
        const self = of(ctx);
        return self.callStopListen(listener_ctx);
    }

    fn callStopListen(self: *MultiplexedAdapter, listener_ctx: *anyopaque) ?foundation.FailureChain {
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.stop_listen.?(listener_ctx, &report);
        return self.teardownFailure(code, report, "stop_listen");
    }

    fn tryRead(ctx: *anyopaque, conn: usize, buf: []u8) isize {
        const self = of(ctx);
        const got = self.table.try_read.?(self.table.ctx, @intCast(conn), buf.ptr, buf.len);
        if (!multiplexedIoResultValid(got, buf.len)) {
            self.failContract(if (got < 0)
                "try_read returned an undocumented negative status"
            else
                "try_read returned more bytes than its capacity");
            return -1;
        }
        return got;
    }

    fn tryWrite(ctx: *anyopaque, conn: usize, bytes: []const u8) isize {
        const self = of(ctx);
        const wrote = self.table.try_write.?(self.table.ctx, @intCast(conn), bytes.ptr, bytes.len);
        if (!multiplexedIoResultValid(wrote, bytes.len)) {
            self.failContract(if (wrote < 0)
                "try_write returned an undocumented negative status"
            else
                "try_write consumed more bytes than supplied");
            return -1;
        }
        return wrote;
    }

    fn failContract(self: *MultiplexedAdapter, message: []const u8) void {
        self.owner.failContract(message);
    }

    fn connClose(ctx: *anyopaque, conn: usize) ?foundation.FailureChain {
        const self = of(ctx);
        return self.callSubjectTeardown(self.table.conn_close.?, conn, "conn_close");
    }

    fn callSubjectTeardown(
        self: *MultiplexedAdapter,
        callback: shared.multiplexed_transport.PancakeMultiplexedSubjectFn,
        subject: usize,
        operation: []const u8,
    ) ?foundation.FailureChain {
        var report = shared.transport_provider.emptyProviderFailure();
        const code = callback(self.table.ctx, @intCast(subject), &report);
        return self.teardownFailure(code, report, operation);
    }

    fn teardownFailure(
        self: *MultiplexedAdapter,
        code: i32,
        report: shared.PancakeProviderFailure,
        operation: []const u8,
    ) ?foundation.FailureChain {
        if (code == PANCAKE_OK) {
            if (providerFailureIsEmpty(report)) return null;
        } else if (!providerFailureIsEmpty(report)) {
            return failureChainFromProvider(code, report) catch {
                self.failContract(operation);
                return foundation.FailureChain.init(error.ProviderContract);
            };
        }
        self.failContract(operation);
        return foundation.FailureChain.init(error.ProviderContract);
    }

    fn takeFailure(ctx: *anyopaque, conn: usize) ?foundation.FailureChain {
        const self = of(ctx);
        var report = std.mem.zeroes(shared.PancakeProviderFailure);
        self.table.conn_take_failure.?(self.table.ctx, @intCast(conn), &report);
        if (providerFailureIsEmpty(report)) return null;
        return failureChainFromProvider(report.result, report) catch {
            self.failContract("multiplexed conn_take_failure returned an invalid report");
            return foundation.FailureChain.init(error.ProviderContract);
        };
    }

    fn connRemoteKey(ctx: *anyopaque, conn: usize) net.multiplexed_resident.ContractError!?crypto.PeerKey {
        const self = of(ctx);
        var key: [crypto.PEER_KEY_BYTES]u8 = undefined;
        const result = self.table.conn_remote_key.?(self.table.ctx, @intCast(conn), &key);
        return switch (result) {
            0 => null,
            1 => crypto.PeerKey.fromSlice(&key) catch unreachable,
            else => {
                self.failContract("conn_remote_key returned an invalid status");
                return error.ProviderContract;
            },
        };
    }
};

fn decodeTransportProfile(profile: *const shared.PancakeTransportProfile) !model.transport.Metadata {
    if (profile.abi_version != shared.transport_provider.PANCAKE_TRANSPORT_PROFILE_ABI_VERSION or
        profile.struct_size < @sizeOf(shared.PancakeTransportProfile))
    {
        shared.setLastError("driver: provider profile has an unsupported ABI", .{});
        return error.InvalidArgument;
    }
    const name_ptr = profile.transport_name orelse {
        shared.setLastError("driver: provider transport_name must be set", .{});
        return error.InvalidArgument;
    };
    if (profile.transport_name_len == 0) {
        shared.setLastError("driver: provider transport_name must be nonempty", .{});
        return error.InvalidArgument;
    }
    const scheme: net.netlayer.DesignatorScheme = switch (profile.designator_scheme) {
        shared.transport_provider.PANCAKE_DESIGNATOR_SCHEME_ADDRESS => .address,
        shared.transport_provider.PANCAKE_DESIGNATOR_SCHEME_KEY => .key,
        else => {
            shared.setLastError("driver: provider has an invalid designator_scheme", .{});
            return error.InvalidArgument;
        },
    };
    const sealed_channel = switch (profile.sealed_channel) {
        shared.transport_provider.PANCAKE_SEALED_CHANNEL_NONE => false,
        shared.transport_provider.PANCAKE_SEALED_CHANNEL_NOISE_XK => true,
        else => {
            shared.setLastError("driver: provider has an invalid sealed_channel", .{});
            return error.InvalidArgument;
        },
    };
    return .{
        .symbol = name_ptr[0..profile.transport_name_len],
        .designator_scheme = scheme,
        .sealed_channel = sealed_channel,
    };
}

fn prepareStreamAdapter(
    registry: *Registry,
    profile: model.transport.Metadata,
    table_ptr: *const shared.PancakeStreamTransport,
) !*StreamAdapter {
    try validateTablePrefix(shared.PancakeStreamTransport, table_ptr, shared.transport_provider.PANCAKE_STREAM_TRANSPORT_ABI_VERSION, "stream");
    const table = table_ptr.*;
    const dial_any = table.start_connect != null or table.finish_connect != null or table.cancel_connect != null;
    const dial = try validateOperationGroup(dial_any, table.start_connect != null and
        table.finish_connect != null and table.cancel_connect != null, "stream dial");
    const listen_completion_any = table.finish_listen != null or table.cancel_listen != null;
    _ = try validateOperationGroup(listen_completion_any, table.finish_listen != null and
        table.cancel_listen != null, "stream listen completion");
    const listen_operation = table.listen != null;
    const listen_any = listen_operation or table.finish_listen != null or table.cancel_listen != null or
        table.listener_wait_acceptable != null or table.listener_readiness_fd != null or
        table.listener_locator != null or table.listener_advertise != null or
        table.listener_restoration_state != null or
        table.accept != null or table.listener_close != null;
    const listen = try validateOperationGroup(listen_any, listen_operation and
        table.listener_wait_acceptable != null and
        table.listener_readiness_fd != null and table.listener_locator != null and
        table.listener_advertise != null and table.accept != null and table.listener_close != null, "stream listen");
    if ((!dial and !listen) or table.read == null or table.write_all == null or table.conn_close == null or table.conn_take_failure == null) {
        shared.setLastError("driver: stream provider has no operation group or connection callbacks", .{});
        return error.InvalidArgument;
    }
    const adapter = try registry.allocator.create(StreamAdapter);
    errdefer registry.allocator.destroy(adapter);
    const owned_profile = try ownProfile(registry, profile);
    errdefer registry.allocator.free(owned_profile.symbol);
    adapter.* = .{
        .owner = registry,
        .table = table,
        .transport = owned_profile.symbol,
        .netlayer_vtable = .{
            .profile = owned_profile,
            .dial = if (dial) .{ .staged = StreamAdapter.startDial } else null,
            .listen = if (listen) StreamAdapter.listen else null,
            .io = StreamAdapter.io,
        },
        .listener_vtable = .{
            .transport_name = owned_profile.symbol,
            .designator_scheme = profile.designator_scheme,
            .sealed_channel = profile.sealed_channel,
            .accept = StreamAdapter.listenerAccept,
            .accept_detailed = StreamAdapter.listenerAcceptDetailed,
            .waitAcceptable = StreamAdapter.listenerWaitAcceptable,
            .wait_acceptable_detailed = StreamAdapter.listenerWaitAcceptableDetailed,
            .localLocator = StreamAdapter.localLocator,
            .canonicalizeLocator = StreamAdapter.canonicalizeLocator,
            .restoration_state = if (table.listener_restoration_state != null) StreamAdapter.listenerRestorationState else null,
            .readiness_fd = StreamAdapter.listenerReadinessFd,
            .close = StreamAdapter.listenerClose,
        },
    };
    return adapter;
}

fn prepareMultiplexedAdapter(
    registry: *Registry,
    table_ptr: *const shared.PancakeMultiplexedTransport,
) !*MultiplexedAdapter {
    try validateTablePrefix(shared.PancakeMultiplexedTransport, table_ptr, shared.multiplexed_transport.PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION, "multiplexed");
    const table = table_ptr.*;
    if (table.readiness_fd == null or table.drain_ready == null or table.try_read == null or
        table.try_write == null or table.conn_close == null or table.conn_take_failure == null or table.conn_remote_key == null)
    {
        shared.setLastError("driver: multiplexed provider readiness and connection callbacks must be set", .{});
        return error.InvalidArgument;
    }
    const dial_any = table.start_connect != null or table.finish_connect != null or table.cancel_connect != null;
    const dial = try validateOperationGroup(dial_any, table.start_connect != null and
        table.finish_connect != null and table.cancel_connect != null, "multiplexed dial");
    const external_claim = table.claim_external != null;
    const listen_completion_any = table.finish_listen != null or table.cancel_listen != null;
    const listen_completion = try validateOperationGroup(
        listen_completion_any,
        table.finish_listen != null and table.cancel_listen != null,
        "multiplexed listen completion",
    );
    const listen_any = table.listen != null or listen_completion_any or
        table.listener_locator != null or
        table.listener_advertise != null or table.listener_restoration_state != null or
        table.finish_accept != null or table.stop_listen != null;
    const listen = try validateOperationGroup(listen_any, table.listen != null and
        table.listener_locator != null and table.listener_advertise != null and
        table.finish_accept != null and table.stop_listen != null, "multiplexed listen");
    if (!dial and !listen and !external_claim) {
        shared.setLastError("driver: multiplexed provider has no operation group", .{});
        return error.InvalidArgument;
    }
    const adapter = try registry.allocator.create(MultiplexedAdapter);
    errdefer registry.allocator.destroy(adapter);
    adapter.* = .{
        .owner = registry,
        .table = table,
        .vtable = .{
            .readiness_fd = MultiplexedAdapter.readinessFd,
            .drain_ready = MultiplexedAdapter.drainReady,
            .dial = if (dial) .{
                .start_connect = MultiplexedAdapter.startConnect,
                .finish_connect = MultiplexedAdapter.finishConnect,
                .cancel_connect = MultiplexedAdapter.cancelConnect,
            } else null,
            .external_claim = if (external_claim) .{
                .claim_external = MultiplexedAdapter.claimExternal,
            } else null,
            .listen = if (listen) .{
                .listen = MultiplexedAdapter.listen,
                .completion = if (listen_completion) .{
                    .finish = MultiplexedAdapter.finishListen,
                    .cancel = MultiplexedAdapter.cancelListen,
                } else null,
                .local_locator = MultiplexedAdapter.localLocator,
                .canonicalize_locator = MultiplexedAdapter.canonicalizeLocator,
                .restoration_state = if (table.listener_restoration_state != null) MultiplexedAdapter.listenerRestorationState else null,
                .finish_accept = MultiplexedAdapter.finishAccept,
                .finish_accept_detailed = MultiplexedAdapter.finishAcceptDetailed,
                .stop_listen = MultiplexedAdapter.stopListen,
            } else null,
            .try_read = MultiplexedAdapter.tryRead,
            .try_write = MultiplexedAdapter.tryWrite,
            .take_failure = MultiplexedAdapter.takeFailure,
            .conn_close = MultiplexedAdapter.connClose,
            .conn_remote_key = MultiplexedAdapter.connRemoteKey,
        },
    };
    return adapter;
}

const Adapter = union(enum) {
    stream: *StreamAdapter,
    multiplexed: *MultiplexedAdapter,

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

    fn deinit(self: Adapter, registry: *Registry) void {
        switch (self) {
            .stream => |adapter| destroyAdapter(registry, adapter),
            .multiplexed => |adapter| registry.allocator.destroy(adapter),
        }
    }
};
