//! Adapt one foreign stream provider table to the native Netlayer contract.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const net = @import("net");
const driver = @import("driver");
const teardown = @import("teardown.zig");
const validation = @import("validation.zig");
const listener = @import("stream_listener.zig");
const owner_mod = @import("owner.zig");
const driver_error = @import("../error.zig");
const shared = @import("c_abi_shared");

const LocatorProjection = shared.locator_adapter.Projection;
const Owner = owner_mod.Owner;
const operationFailureFromProvider = owner_mod.operationFailureFromProvider;
const failureChainFromProvider = owner_mod.failureChainFromProvider;
const dialErrorFromCode = owner_mod.dialErrorFromCode;
const dialFailureFromProvider = owner_mod.dialFailureFromProvider;
const providerFailureIsEmpty = owner_mod.providerFailureIsEmpty;
const PANCAKE_OK = shared.PANCAKE_OK;

fn ownProfile(owner: *Owner, profile: model.transport.Metadata) !model.transport.Metadata {
    var owned = profile;
    owned.symbol = try owner.allocator.dupe(u8, profile.symbol);
    return owned;
}

// ── Foreign stream adapter ──────────────────────────────────────────────────

pub const Adapter = struct {
    pub const ConnectionBuildOutcome = union(enum) {
        connected: net.Connection,
        failed: driver.OperationFailure,
    };

    owner: *Owner,
    table: shared.PancakeStreamTransport,
    transport: []const u8,
    netlayer_vtable: net.netlayer.Netlayer.VTable,
    listener_vtable: net.netlayer.Listener.VTable,

    const Source = struct {
        adapter: *Adapter,
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
        adapter: *Adapter,
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

    pub fn netlayer(self: *Adapter) net.netlayer.Netlayer {
        return .{ .ctx = self, .vtable = &self.netlayer_vtable };
    }

    pub fn deinit(self: *Adapter) void {
        self.owner.allocator.free(self.transport);
        self.owner.allocator.destroy(self);
    }

    fn of(ctx: *anyopaque) *Adapter {
        return @ptrCast(@alignCast(ctx));
    }

    fn mapDialError(code: i32) net.netlayer.DialError {
        return dialErrorFromCode(code);
    }

    pub fn makeConnection(
        self: *Adapter,
        peer: *engine.Peer,
        bufs: net.netlayer.Buffers,
        handle: *anyopaque,
        fd: i32,
    ) ConnectionBuildOutcome {
        const source: Source = .{ .adapter = self, .conn = handle };
        const stream = ForeignStream.create(peer.allocator, source, source, bufs, .{
            .adapter = self,
            .conn = handle,
            .fd = fd,
        }) catch |err| {
            var failure = driver.OperationFailure.fromError(err);
            if (self.closeConnection(handle)) |cleanup| failure.noteFailure(cleanup);
            return .{ .failed = failure };
        };
        return .{ .connected = stream.intoConnection(self.owner.io, peer) };
    }

    pub fn closeConnection(self: *Adapter, handle: *anyopaque) ?driver.OperationFailure {
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.conn_close.?(self.table.ctx, handle, &report);
        if (code == PANCAKE_OK) {
            if (providerFailureIsEmpty(report)) return null;
            self.owner.failContract("stream close reported failure data on success");
            self.owner.retainContradictoryReport(report, null);
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
            validation.projectOperationOptions(options, &options_storage),
            &attempt,
            &fd,
            &report,
        );
        if (code != PANCAKE_OK) {
            var failure = dialFailureFromProvider(code, report) catch blk: {
                self.owner.failContract("stream connect start returned an invalid structured failure");
                break :blk net.netlayer.DialFailure.fromChain(error.InvalidOptions, .init(error.ProviderContract));
            };
            if (attempt != null or fd != -1) {
                self.owner.failContract("stream connect start published outputs on failure");
                if (attempt) |handle| if (self.cancelDialHandle(handle)) |cleanup|
                    failure.chain.noteChain(cleanup);
                self.owner.runtime.noteTerminalOperationFailure(.fromDialFailure(failure));
            }
            failure.classification = mapDialError(code);
            return .{ .failed = failure };
        }
        if (!providerFailureIsEmpty(report)) {
            self.owner.failContract("stream connect start reported failure data on success");
            const cleanup = if (attempt) |handle| self.cancelDialHandle(handle) else null;
            self.owner.retainContradictoryReport(report, cleanup);
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
            var failure = dialFailureFromProvider(code, report) catch blk: {
                self.owner.failContract("stream connect finish returned an invalid structured failure");
                break :blk net.netlayer.DialFailure.fromChain(error.InvalidOptions, .init(error.ProviderContract));
            };
            if (handle != null or fd != -1) {
                self.owner.failContract("stream connect finish published outputs on failure");
                if (handle) |conn| if (self.closeConnection(conn)) |cleanup|
                    failure.chain.noteChain(cleanup.toChain());
                self.owner.runtime.noteTerminalOperationFailure(.fromDialFailure(failure));
            }
            failure.classification = mapDialError(code);
            return .{ .failed = failure };
        }
        if (!providerFailureIsEmpty(report)) {
            self.owner.failContract("stream connect finish reported failure data on success");
            const cleanup = if (handle) |conn|
                if (self.closeConnection(conn)) |failure| failure.toChain() else null
            else
                null;
            self.owner.retainContradictoryReport(report, cleanup);
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
        return switch (self.makeConnection(peer, bufs, conn, fd)) {
            .connected => |connection| .{ .connected = connection },
            .failed => |failure| .{ .failed = .fromChain(
                dialErrorFromCode(driver_error.code(failure.kind)),
                failure.toChain(),
            ) },
        };
    }

    fn cancelDial(owner: *anyopaque, attempt: *anyopaque) ?foundation.FailureChain {
        const self = of(owner);
        return self.callStreamCancel(self.table.cancel_connect.?, attempt, "stream cancel_connect");
    }

    fn cancelDialHandle(self: *Adapter, attempt: *anyopaque) ?foundation.FailureChain {
        return self.callStreamCancel(self.table.cancel_connect.?, attempt, "stream cancel_connect");
    }

    pub fn callStreamCancel(
        self: *Adapter,
        callback: anytype,
        attempt: *anyopaque,
        operation: []const u8,
    ) ?foundation.FailureChain {
        var report = shared.transport_provider.emptyProviderFailure();
        const code = callback(attempt, &report);
        if (code == PANCAKE_OK) {
            if (providerFailureIsEmpty(report)) return null;
            self.owner.failContract(operation);
            self.owner.retainContradictoryReport(report, null);
            return foundation.FailureChain.init(error.ProviderContract);
        } else if (!providerFailureIsEmpty(report)) {
            return failureChainFromProvider(code, report) catch {
                self.owner.failContract(operation);
                return foundation.FailureChain.init(error.ProviderContract);
            };
        }
        self.owner.failContract(operation);
        return foundation.FailureChain.init(error.ProviderContract);
    }
    fn io(ctx: *anyopaque) ?std.Io {
        return of(ctx).owner.io;
    }
};

pub fn prepare(
    owner: *Owner,
    profile: model.transport.Metadata,
    table_ptr: *const shared.PancakeStreamTransport,
) !*Adapter {
    try validation.tablePrefix(shared.PancakeStreamTransport, table_ptr, shared.transport_provider.PANCAKE_STREAM_TRANSPORT_ABI_VERSION, "stream");
    const table = table_ptr.*;
    const dial_any = table.start_connect != null or table.finish_connect != null or table.cancel_connect != null;
    const dial = try validation.operationGroup(dial_any, table.start_connect != null and
        table.finish_connect != null and table.cancel_connect != null, "stream dial");
    const listen_completion_any = table.finish_listen != null or table.cancel_listen != null;
    _ = try validation.operationGroup(listen_completion_any, table.finish_listen != null and
        table.cancel_listen != null, "stream listen completion");
    const listen_operation = table.listen != null;
    const listen_any = listen_operation or table.finish_listen != null or table.cancel_listen != null or
        table.listener_wait_acceptable != null or table.listener_readiness_fd != null or
        table.listener_locator != null or table.listener_advertise != null or
        table.listener_restoration_state != null or
        table.accept != null or table.listener_close != null;
    const listen = try validation.operationGroup(listen_any, listen_operation and
        table.listener_wait_acceptable != null and
        table.listener_readiness_fd != null and table.listener_locator != null and
        table.listener_advertise != null and table.accept != null and table.listener_close != null, "stream listen");
    if ((!dial and !listen) or table.read == null or table.write_all == null or table.conn_close == null or table.conn_take_failure == null) {
        shared.setLastError("driver: stream provider has no operation group or connection callbacks", .{});
        return error.InvalidArgument;
    }
    const adapter = try owner.allocator.create(Adapter);
    errdefer owner.allocator.destroy(adapter);
    const owned_profile = try ownProfile(owner, profile);
    errdefer owner.allocator.free(owned_profile.symbol);
    adapter.* = .{
        .owner = owner,
        .table = table,
        .transport = owned_profile.symbol,
        .netlayer_vtable = .{
            .profile = owned_profile,
            .dial = if (dial) .{ .staged = Adapter.startDial } else null,
            .listen = if (listen) listener.listen else null,
            .io = Adapter.io,
        },
        .listener_vtable = .{
            .transport_name = owned_profile.symbol,
            .designator_scheme = profile.designator_scheme,
            .sealed_channel = profile.sealed_channel,
            .accept = listener.listenerAcceptOutcome,
            .wait_acceptable = listener.listenerWaitAcceptableOutcome,
            .local_locator = listener.localLocatorOutcome,
            .canonicalize_locator = listener.canonicalizeLocatorOutcome,
            .restoration_state = if (table.listener_restoration_state != null) listener.listenerRestorationStateOutcome else null,
            .readiness_fd = listener.listenerReadinessFd,
            .close = listener.listenerClose,
        },
    };
    return adapter;
}
