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

const shared = @import("c_abi_shared");

const crypto = foundation.crypto;
const LocatorProjection = shared.locator_adapter.Projection;

const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;

fn multiplexedIoResultValid(result: isize, capacity: usize) bool {
    if (result == -1 or result == shared.PANCAKE_MULTIPLEXED_WOULD_BLOCK) return true;
    if (result < 0) return false;
    return @as(usize, @intCast(result)) <= capacity;
}

const ProviderLease = struct {
    ctx: ?*anyopaque,
    release: shared.transport_provider.PancakeTransportReleaseFn,
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
    allocator: std.mem.Allocator,
    io: std.Io,
    adapters: std.ArrayListUnmanaged(Adapter) = .empty,
    leases: std.ArrayListUnmanaged(ProviderLease) = .empty,
    contract_failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Registry {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Registry) void {
        for (self.adapters.items) |adapter| adapter.deinit(self);
        self.adapters.deinit(self.allocator);
        var lease_index = self.leases.items.len;
        while (lease_index != 0) {
            lease_index -= 1;
            const lease = self.leases.items[lease_index];
            lease.release(lease.ctx);
        }
        self.leases.deinit(self.allocator);
    }

    pub fn failed(self: *const Registry) bool {
        return self.contract_failed;
    }

    pub fn terminalCode(self: *const Registry) ?i32 {
        if (!self.contract_failed) return null;
        shared.setLastError("driver: a transport provider violated its callback contract; release the loop", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }

    fn failContract(self: *Registry, message: []const u8) void {
        self.contract_failed = true;
        shared.setLastError("driver: transport provider contract violation: {s}", .{message});
    }

    /// Install one package atomically. Every profile and implementation table
    /// is validated and allocated before HostRuntime publishes any registration.
    pub fn addProvider(
        self: *Registry,
        runtime: *driver.HostRuntime,
        provider: ?*const shared.PancakeTransportProvider,
    ) i32 {
        const package = provider orelse return PANCAKE_ERR_NULL_POINTER;
        if (package.abi_version != shared.transport_provider.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION or
            package.struct_size < @sizeOf(shared.PancakeTransportProvider) or
            package.entry_count == 0 or package.entries == null or
            package.retain == null or package.release == null)
        {
            shared.setLastError("driver: invalid transport provider package", .{});
            return PANCAKE_ERR_INVALID_ARGUMENT;
        }

        const entries = package.entries.?[0..package.entry_count];
        const retain_code = package.retain.?(package.lease_ctx);
        if (retain_code != PANCAKE_OK) {
            shared.setLastError("driver: transport provider refused its registration lease", .{});
            return retain_code;
        }
        var retained = true;
        defer if (retained) package.release.?(package.lease_ctx);

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

        for (entries, prepared_entries) |entry, *prepared_entry| {
            const profile_table = entry.profile orelse {
                shared.setLastError("driver: provider entry has no transport profile", .{});
                return PANCAKE_ERR_INVALID_ARGUMENT;
            };
            const profile = decodeTransportProfile(profile_table) catch |err| return errToCode(err);
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

        self.adapters.ensureUnusedCapacity(self.allocator, owned) catch
            return shared.PANCAKE_ERR_INTERNAL;
        self.leases.ensureUnusedCapacity(self.allocator, 1) catch
            return shared.PANCAKE_ERR_INTERNAL;
        runtime.addProviders(registrations, resident_indices) catch |err| return errToCode(err);
        self.adapters.appendSliceAssumeCapacity(owned_adapters[0..owned]);
        self.leases.appendAssumeCapacity(.{
            .ctx = package.lease_ctx,
            .release = package.release.?,
        });
        retained = false;
        published = true;
        return PANCAKE_OK;
    }
};

fn errToCode(err: anyerror) i32 {
    if (err != error.InvalidArgument) shared.setLastError("driver provider: {s}", .{@errorName(err)});
    return switch (err) {
        error.OutOfMemory => shared.PANCAKE_ERR_INTERNAL,
        error.InvalidArgument,
        error.ReadinessDescriptorConflict,
        error.ReadinessUnavailable,
        error.TransportSemanticsConflict,
        error.TransportAlreadyRegistered,
        error.InvalidTransportName,
        => PANCAKE_ERR_INVALID_ARGUMENT,
        else => shared.PANCAKE_ERR_IO,
    };
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
            self.adapter.table.conn_close.?(self.adapter.table.ctx, self.conn);
        }

        pub fn socketHandle(self: ConnContext) ?std.Io.net.Socket.Handle {
            return self.fd;
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
            self.table.conn_close.?(self.table.ctx, handle);
            return err;
        };
        return stream.intoConnection(self.owner.io, peer);
    }

    fn startDial(
        ctx: *anyopaque,
        locator: model.PeerLocator,
    ) net.netlayer.DialError!net.netlayer.ConnectAttempt {
        const self = of(ctx);
        var attempt: ?*anyopaque = null;
        var fd: i32 = -1;
        var hint_stack: [shared.locator_adapter.inline_hint_capacity]shared.PancakeLocatorHintView = undefined;
        var projection = LocatorProjection.init(self.owner.allocator, locator, &hint_stack) catch return error.OutOfMemory;
        defer projection.deinit(self.owner.allocator);
        const code = self.table.start_connect.?(
            self.table.ctx,
            &projection.view,
            &attempt,
            &fd,
        );
        if (code != PANCAKE_OK) return mapDialError(code);
        const handle = attempt orelse {
            self.owner.failContract("stream connect start succeeded without an attempt handle");
            return error.ConnectionLost;
        };
        if (fd < 0) {
            self.table.cancel_connect.?(handle);
            self.owner.failContract("stream connect start succeeded without a readiness descriptor");
            return error.ConnectionLost;
        }
        return .{
            .owner = self,
            .attempt = handle,
            .vtable = &connect_attempt_vtable,
            .readiness_fd = fd,
        };
    }

    const connect_attempt_vtable = net.netlayer.ConnectAttempt.VTable{
        .finish = finishDial,
        .cancel = cancelDial,
    };

    fn finishDial(
        owner: *anyopaque,
        attempt: *anyopaque,
        peer: *engine.Peer,
        bufs: net.netlayer.Buffers,
    ) net.netlayer.DialError!net.Connection {
        const self = of(owner);
        var handle: ?*anyopaque = null;
        var fd: i32 = -1;
        const code = self.table.finish_connect.?(
            attempt,
            &handle,
            &fd,
        );
        if (code != PANCAKE_OK) return mapDialError(code);
        const conn = handle orelse {
            self.owner.failContract("stream connect finish succeeded without a connection handle");
            return error.ConnectionLost;
        };
        if (fd < 0) {
            self.table.conn_close.?(self.table.ctx, conn);
            self.owner.failContract("stream connect finish succeeded without a readiness descriptor");
            return error.ConnectionLost;
        }
        return self.makeConnection(peer, bufs, conn, fd);
    }

    fn cancelDial(owner: *anyopaque, attempt: *anyopaque) void {
        const self = of(owner);
        self.table.cancel_connect.?(attempt);
    }

    fn listen(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        config: net.netlayer.ListenConfig,
    ) net.netlayer.ListenError!net.netlayer.Listener {
        const self = of(ctx);
        var identity_storage: [crypto.PeerKey.designator_len]u8 = undefined;
        const identity: []const u8 = if (config.identity) |key| blk: {
            identity_storage = key.toDesignator();
            break :blk &identity_storage;
        } else &.{};
        var handle: ?*anyopaque = null;
        const code = self.table.listen.?(
            self.table.ctx,
            config.designator.ptr,
            config.designator.len,
            identity.ptr,
            identity.len,
            &handle,
        );
        if (code != PANCAKE_OK) return switch (code) {
            shared.PANCAKE_ERR_INVALID_ARGUMENT => error.InvalidAddress,
            shared.PANCAKE_ERR_INTERNAL => error.OutOfMemory,
            else => error.BindFailed,
        };
        const listener_handle = handle orelse {
            self.owner.failContract("stream listen succeeded without a listener handle");
            return error.BindFailed;
        };
        const box = allocator.create(ListenerBox) catch |err| {
            self.table.listener_close.?(self.table.ctx, listener_handle);
            return err;
        };
        box.* = .{ .adapter = self, .handle = listener_handle };
        return .{ .ctx = box, .vtable = &self.listener_vtable };
    }

    fn listenerOf(ctx: *anyopaque) *ListenerBox {
        return @ptrCast(@alignCast(ctx));
    }

    fn listenerAccept(ctx: *anyopaque, peer: *engine.Peer, bufs: net.netlayer.Buffers) net.netlayer.AcceptError!net.Connection {
        const box = listenerOf(ctx);
        var handle: ?*anyopaque = null;
        var fd: i32 = -1;
        const code = box.adapter.table.accept.?(
            box.adapter.table.ctx,
            box.handle,
            &handle,
            &fd,
        );
        if (code != PANCAKE_OK) return switch (code) {
            shared.PANCAKE_ERR_INTERNAL => error.OutOfMemory,
            else => error.ConnectionLost,
        };
        const conn = handle orelse {
            box.adapter.owner.failContract("stream accept succeeded without a connection handle");
            return error.ConnectionLost;
        };
        if (fd < 0) {
            box.adapter.table.conn_close.?(box.adapter.table.ctx, conn);
            box.adapter.owner.failContract("stream accept succeeded without a readiness descriptor");
            return error.ConnectionLost;
        }
        return box.adapter.makeConnection(peer, bufs, conn, fd) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ConnectionLost,
        };
    }

    fn listenerWait(ctx: *anyopaque, timeout_ms: i32, callback: shared.transport_provider.PancakeStreamListenerWaitFn) net.netlayer.AcceptError!bool {
        const box = listenerOf(ctx);
        return switch (callback(box.adapter.table.ctx, box.handle, timeout_ms)) {
            PANCAKE_OK => true,
            PANCAKE_ERR_WOULD_BLOCK => false,
            shared.PANCAKE_ERR_INTERNAL => error.OutOfMemory,
            else => error.ConnectionLost,
        };
    }

    fn listenerWaitReady(ctx: *anyopaque, timeout_ms: i32) net.netlayer.AcceptError!bool {
        const box = listenerOf(ctx);
        return listenerWait(ctx, timeout_ms, box.adapter.table.listener_wait_ready.?);
    }

    fn listenerWaitAcceptable(ctx: *anyopaque, timeout_ms: i32) net.netlayer.AcceptError!bool {
        const box = listenerOf(ctx);
        return listenerWait(ctx, timeout_ms, box.adapter.table.listener_wait_acceptable.?);
    }

    fn listenerLocator(ctx: *anyopaque, allocator: std.mem.Allocator) net.netlayer.ListenError!model.PeerLocator {
        const box = listenerOf(ctx);
        return (provider_locator.Listener{
            .ctx = box.handle,
            .transport = box.adapter.transport,
            .local = box.adapter.table.listener_locator.?,
            .canonicalize = box.adapter.table.listener_advertise.?,
        }).localLocator(allocator);
    }

    fn listenerAdvertise(
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

    fn listenerReadinessFd(ctx: *anyopaque) i32 {
        const box = listenerOf(ctx);
        const fd = box.adapter.table.listener_readiness_fd.?(
            box.adapter.table.ctx,
            box.handle,
        );
        if (fd < 0) box.adapter.owner.failContract("stream listener returned an invalid readiness descriptor");
        return fd;
    }

    fn listenerClose(ctx: *anyopaque) void {
        const box = listenerOf(ctx);
        const allocator = box.adapter.owner.allocator;
        box.adapter.table.listener_close.?(box.adapter.table.ctx, box.handle);
        allocator.destroy(box);
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
            const got = self.table.drain_ready.?(self.table.ctx, &c_buf, cap);
            if (got > cap) {
                self.failContract("drain_ready returned more records than its capacity");
                return error.ProviderContract;
            }
            const event_mask = net.multiplexed_resident.ev_readable |
                net.multiplexed_resident.ev_writable |
                net.multiplexed_resident.ev_closed |
                net.multiplexed_resident.ev_accept |
                net.multiplexed_resident.ev_connect;
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
                if (src.events & net.multiplexed_resident.ev_accept != 0 and self.vtable.listen == null) {
                    self.failContract("dial-only resident emitted an accept event");
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
    ) net.netlayer.DialError!void {
        const self = of(ctx);
        var hint_stack: [shared.locator_adapter.inline_hint_capacity]shared.PancakeLocatorHintView = undefined;
        var projection = LocatorProjection.init(self.owner.allocator, locator, &hint_stack) catch return error.OutOfMemory;
        defer projection.deinit(self.owner.allocator);
        const code = self.table.start_connect.?(
            self.table.ctx,
            @intCast(request_id),
            &projection.view,
        );
        if (code != PANCAKE_OK) return dialErrorFromCode(code);
    }

    fn finishConnect(ctx: *anyopaque, request_id: usize) net.netlayer.DialError!usize {
        const self = of(ctx);
        var conn: u64 = 0;
        const code = self.table.finish_connect.?(self.table.ctx, @intCast(request_id), &conn);
        if (code != PANCAKE_OK) return dialErrorFromCode(code);
        return std.math.cast(usize, conn) orelse {
            self.failContract("finish_connect returned a connection id outside the host range");
            return error.ConnectionLost;
        };
    }

    fn cancelConnect(ctx: *anyopaque, request_id: usize) void {
        const self = of(ctx);
        self.table.cancel_connect.?(self.table.ctx, @intCast(request_id));
    }

    fn claimExternal(ctx: *anyopaque, subject: usize) net.netlayer.DialError!usize {
        const self = of(ctx);
        var conn: u64 = 0;
        const code = self.table.claim_external.?(self.table.ctx, @intCast(subject), &conn);
        if (code != PANCAKE_OK) return dialErrorFromCode(code);
        return std.math.cast(usize, conn) orelse {
            self.failContract("claim_external returned a connection id outside the host range");
            return error.ConnectionLost;
        };
    }

    fn startListen(
        ctx: *anyopaque,
        route_id: usize,
        transport: []const u8,
        requested_designator: []const u8,
    ) net.netlayer.ListenError!*anyopaque {
        const self = of(ctx);
        var listener: ?*anyopaque = null;
        const code = self.table.start_listen.?(
            self.table.ctx,
            @intCast(route_id),
            transport.ptr,
            transport.len,
            requested_designator.ptr,
            requested_designator.len,
            &listener,
        );
        return switch (code) {
            PANCAKE_OK => listener orelse {
                self.failContract("start_listen succeeded without a listener handle");
                return error.BindFailed;
            },
            shared.PANCAKE_ERR_INVALID_ARGUMENT => error.InvalidAddress,
            shared.PANCAKE_ERR_INTERNAL => error.OutOfMemory,
            else => error.BindFailed,
        };
    }

    fn listenerLocator(
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

    fn listenerAdvertise(
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

    fn finishAccept(ctx: *anyopaque, listener_ctx: *anyopaque) net.netlayer.AcceptError!?usize {
        const self = of(ctx);
        var conn: u64 = 0;
        const code = self.table.finish_accept.?(listener_ctx, &conn);
        return switch (code) {
            PANCAKE_OK => std.math.cast(usize, conn) orelse {
                self.failContract("finish_accept returned a connection id outside the host range");
                return error.ConnectionLost;
            },
            PANCAKE_ERR_WOULD_BLOCK => null,
            shared.PANCAKE_ERR_INTERNAL => error.OutOfMemory,
            else => error.ConnectionLost,
        };
    }

    fn stopListen(ctx: *anyopaque, listener_ctx: *anyopaque) void {
        const self = of(ctx);
        self.table.stop_listen.?(listener_ctx);
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

    fn connClose(ctx: *anyopaque, conn: usize) void {
        const self = of(ctx);
        self.table.conn_close.?(self.table.ctx, @intCast(conn));
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
    const symbol = name_ptr[0..profile.transport_name_len];
    return model.transport.metadataFromClaim(symbol, scheme, sealed_channel) catch |err| {
        switch (err) {
            error.InvalidTransportSymbol => shared.setLastError("driver: provider transport_name is not an OCapN transport symbol", .{}),
            error.TransportSemanticsConflict => shared.setLastError("driver: provider conflicts with known transport semantics", .{}),
        }
        return error.InvalidArgument;
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
    const listen_any = table.listen != null or table.listener_wait_ready != null or
        table.listener_wait_acceptable != null or table.listener_readiness_fd != null or
        table.listener_locator != null or table.listener_advertise != null or
        table.accept != null or table.listener_close != null;
    const listen = try validateOperationGroup(listen_any, table.listen != null and
        table.listener_wait_ready != null and table.listener_wait_acceptable != null and
        table.listener_readiness_fd != null and table.listener_locator != null and
        table.listener_advertise != null and table.accept != null and table.listener_close != null, "stream listen");
    if ((!dial and !listen) or table.read == null or table.write_all == null or table.conn_close == null) {
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
            .dial = null,
            .start_dial = if (dial) StreamAdapter.startDial else null,
            .listen = if (listen) StreamAdapter.listen else null,
            .io = StreamAdapter.io,
        },
        .listener_vtable = .{
            .transport_name = owned_profile.symbol,
            .designator_scheme = profile.designator_scheme,
            .sealed_channel = profile.sealed_channel,
            .accept = StreamAdapter.listenerAccept,
            .waitAcceptable = StreamAdapter.listenerWaitAcceptable,
            .waitReady = StreamAdapter.listenerWaitReady,
            .localLocator = StreamAdapter.listenerLocator,
            .canonicalizeLocator = StreamAdapter.listenerAdvertise,
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
        table.try_write == null or table.conn_close == null or table.conn_remote_key == null)
    {
        shared.setLastError("driver: multiplexed provider readiness and connection callbacks must be set", .{});
        return error.InvalidArgument;
    }
    const dial_any = table.start_connect != null or table.finish_connect != null or table.cancel_connect != null;
    const dial = try validateOperationGroup(dial_any, table.start_connect != null and
        table.finish_connect != null and table.cancel_connect != null, "multiplexed dial");
    const external_claim = table.claim_external != null;
    const listen_any = table.start_listen != null or table.listener_locator != null or
        table.listener_advertise != null or table.finish_accept != null or table.stop_listen != null;
    const listen = try validateOperationGroup(listen_any, table.start_listen != null and
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
                .start_listen = MultiplexedAdapter.startListen,
                .listener_locator = MultiplexedAdapter.listenerLocator,
                .listener_advertise = MultiplexedAdapter.listenerAdvertise,
                .finish_accept = MultiplexedAdapter.finishAccept,
                .stop_listen = MultiplexedAdapter.stopListen,
            } else null,
            .try_read = MultiplexedAdapter.tryRead,
            .try_write = MultiplexedAdapter.tryWrite,
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
