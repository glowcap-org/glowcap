//! Adapt one foreign multiplexed provider table to the native resident contract.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");
const provider_locator = @import("../provider_locator.zig");
const teardown = @import("teardown.zig");
const validation = @import("validation.zig");
const connection_io = @import("multiplexed_connection.zig");
const owner_mod = @import("owner.zig");
const shared = @import("c_abi_shared");

const LocatorProjection = shared.locator_adapter.Projection;
const Owner = owner_mod.Owner;
const listenerRestorationOutcome = owner_mod.listenerRestorationOutcome;
const operationFailureFromProvider = owner_mod.operationFailureFromProvider;
const failureChainFromProvider = owner_mod.failureChainFromProvider;
const dialErrorFromCode = owner_mod.dialErrorFromCode;
const dialFailureFromProvider = owner_mod.dialFailureFromProvider;
const providerFailureIsEmpty = owner_mod.providerFailureIsEmpty;
const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;

// ── Multiplexed-transport adapter ────────────────────────────────────────────

/// One C multiplexed runtime adapted back into the Zig `MultiplexedResident`
/// contract. Transport profile metadata belongs to provider entries, so one
/// adapter can realize several profiles through one readiness descriptor.
pub const Adapter = struct {
    owner: *Owner,
    table: shared.PancakeMultiplexedTransport,
    vtable: net.MultiplexedResident.VTable,

    pub fn multiplexedResident(self: *Adapter) net.MultiplexedResident {
        return .{ .ctx = self, .vtable = &self.vtable };
    }

    fn of(ctx: *anyopaque) *Adapter {
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
                if (got != 0) self.failContract("drain_ready published a count on failure");
                self.owner.runtime.noteTerminalOperationFailure(failure);
                return error.ProviderContract;
            }
            if (!providerFailureIsEmpty(report)) {
                self.failContract("drain_ready reported failure data on success");
                self.owner.retainContradictoryReport(report, null);
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
            validation.projectOperationOptions(options, &options_storage),
            &report,
        );
        if (code != PANCAKE_OK) {
            const failure = dialFailureFromProvider(code, report) catch {
                self.failContract("multiplexed connect start returned an invalid structured failure");
                return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
            };
            return .{ .failed = failure };
        }
        if (!providerFailureIsEmpty(report)) {
            self.failContract("multiplexed connect start reported failure data on success");
            const cleanup = self.callSubjectTeardown(self.table.cancel_connect.?, request_id, "cancel_connect");
            self.owner.retainContradictoryReport(report, cleanup);
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
            var failure = dialFailureFromProvider(code, report) catch blk: {
                self.failContract("multiplexed connect finish returned an invalid structured failure");
                break :blk net.netlayer.DialFailure.fromChain(error.InvalidOptions, .init(error.ProviderContract));
            };
            if (conn != 0) {
                self.failContract("finish_connect published an output on failure");
                if (self.callSubjectTeardown(self.table.conn_close.?, @intCast(conn), "conn_close")) |cleanup|
                    failure.chain.noteChain(cleanup);
                self.owner.runtime.noteTerminalOperationFailure(.fromDialFailure(failure));
            }
            return .{ .failed = failure };
        }
        if (!providerFailureIsEmpty(report)) {
            self.failContract("multiplexed connect finish reported failure data on success");
            const cleanup = if (conn != 0)
                self.callSubjectTeardown(self.table.conn_close.?, @intCast(conn), "conn_close")
            else
                null;
            self.owner.retainContradictoryReport(report, cleanup);
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
            const cleanup = if (conn != 0)
                self.callSubjectTeardown(self.table.conn_close.?, conn, "claim_external rollback")
            else
                null;
            self.owner.retainContradictoryReport(report, cleanup);
            return .{ .failed = .fromChain(error.InvalidOptions, .init(error.ProviderContract)) };
        }
        if (code != PANCAKE_OK) {
            var chain = failureChainFromProvider(code, report) catch blk: {
                self.failContract("claim_external returned an invalid structured failure");
                break :blk foundation.FailureChain.init(error.ProviderContract);
            };
            if (conn != 0) {
                self.failContract("claim_external published an output on failure");
                if (self.callSubjectTeardown(self.table.conn_close.?, conn, "claim_external rollback")) |cleanup|
                    chain.noteChain(cleanup);
                self.owner.runtime.noteTerminalOperationFailure(.fromChain(chain));
            }
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
    ) net.multiplexed_resident.MultiplexedResident.RawListenStartOutcome {
        const self = of(ctx);
        var result = validation.emptyListenResult();
        var options_storage: shared.PancakeTransportOperationOptions = undefined;
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.listen.?(
            self.table.ctx,
            @intCast(route_id),
            transport.ptr,
            transport.len,
            requested_designator.ptr,
            requested_designator.len,
            validation.projectOperationOptions(options, &options_storage),
            &result,
            &report,
        );
        if (code != PANCAKE_OK) {
            var failure = failureChainFromProvider(code, report) catch blk: {
                self.failContract("multiplexed listen returned an invalid structured failure");
                break :blk net.netlayer.ListenFailure.init(error.ProviderContract);
            };
            if (!validation.listenResultUntouched(result)) {
                self.failContract("multiplexed listen published outputs on failure");
                if (result.listener) |listener| if (self.stopListenRollback(listener)) |cleanup|
                    failure.noteChain(cleanup);
                if (self.table.cancel_listen) |cancel| if (self.callSubjectTeardown(cancel, route_id, "cancel_listen")) |cleanup|
                    failure.noteChain(cleanup);
                self.owner.runtime.noteTerminalOperationFailure(.fromChain(failure));
            }
            return .{ .failed = failure };
        }
        if (!providerFailureIsEmpty(report)) {
            self.failContract("multiplexed listen reported failure data on success");
            var failure = net.netlayer.ListenFailure.init(error.ProviderContract);
            var cleanup_chain: ?foundation.FailureChain = null;
            if (result.listener) |listener| if (self.stopListenRollback(listener)) |cleanup| {
                failure.noteChain(cleanup);
                teardown.append(&cleanup_chain, cleanup);
            };
            if (self.table.cancel_listen) |cancel| if (self.callSubjectTeardown(cancel, route_id, "cancel_listen")) |cleanup| {
                failure.noteChain(cleanup);
                teardown.append(&cleanup_chain, cleanup);
            };
            self.owner.retainContradictoryReport(report, cleanup_chain);
            return .{ .failed = failure };
        }
        return switch (result.state) {
            shared.PANCAKE_LISTEN_READY => blk: {
                const listener = result.listener orelse {
                    if (self.table.cancel_listen) |cancel| if (self.callSubjectTeardown(cancel, route_id, "cancel_listen")) |cleanup|
                        self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                    self.failContract("ready multiplexed listen returned no listener");
                    return .{ .failed = .init(error.ProviderContract) };
                };
                if (result.attempt != null or result.readiness_fd != -1) {
                    if (self.stopListenRollback(listener)) |cleanup| self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                    self.failContract("ready multiplexed listen returned pending fields");
                    return .{ .failed = .init(error.ProviderContract) };
                }
                break :blk .{ .admitted = .{ .ready = listener } };
            },
            shared.PANCAKE_LISTEN_PENDING => blk: {
                if (self.table.finish_listen == null or self.table.cancel_listen == null) {
                    if (result.listener) |listener| if (self.stopListenRollback(listener)) |cleanup|
                        self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                    self.failContract("immediate-only multiplexed listener returned pending");
                    return .{ .failed = .init(error.ProviderContract) };
                }
                if (result.listener != null or result.attempt != null or result.readiness_fd != -1) {
                    if (result.listener) |listener| if (self.stopListenRollback(listener)) |cleanup|
                        self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                    if (self.callSubjectTeardown(self.table.cancel_listen.?, route_id, "cancel_listen")) |cleanup|
                        self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                    self.failContract("pending multiplexed listen returned stream-owned fields");
                    return .{ .failed = .init(error.ProviderContract) };
                }
                break :blk .{ .admitted = .pending };
            },
            else => {
                if (result.listener) |listener| if (self.stopListenRollback(listener)) |cleanup|
                    self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                if (self.table.cancel_listen) |cancel| if (self.callSubjectTeardown(cancel, route_id, "cancel_listen")) |cleanup|
                    self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                self.failContract("multiplexed listen returned an unknown state");
                return .{ .failed = .init(error.ProviderContract) };
            },
        };
    }

    fn finishListen(ctx: *anyopaque, route_id: usize) net.multiplexed_resident.MultiplexedResident.RawListenFinishOutcome {
        const self = of(ctx);
        var listener: ?*anyopaque = null;
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.finish_listen.?(self.table.ctx, @intCast(route_id), &listener, &report);
        if (code != PANCAKE_OK) {
            var failure = failureChainFromProvider(code, report) catch blk: {
                self.failContract("multiplexed listener finish returned an invalid structured failure");
                break :blk net.netlayer.ListenFailure.init(error.ProviderContract);
            };
            if (listener) |handle| {
                self.failContract("multiplexed listener finish published an output on failure");
                if (self.stopListenRollback(handle)) |cleanup| failure.noteChain(cleanup);
                self.owner.runtime.noteTerminalOperationFailure(.fromChain(failure));
            }
            return .{ .failed = failure };
        }
        if (!providerFailureIsEmpty(report)) {
            self.failContract("multiplexed listener finish reported failure data on success");
            var failure = net.netlayer.ListenFailure.init(error.ProviderContract);
            const cleanup = if (listener) |handle| self.stopListenRollback(handle) else null;
            if (cleanup) |consequence| failure.noteChain(consequence);
            self.owner.retainContradictoryReport(report, cleanup);
            return .{ .failed = failure };
        }
        const handle = listener orelse {
            self.failContract("multiplexed listener finish returned no listener");
            return .{ .failed = .init(error.ProviderContract) };
        };
        return .{ .listener = handle };
    }

    fn cancelListen(ctx: *anyopaque, route_id: usize) ?foundation.FailureChain {
        const self = of(ctx);
        return self.callSubjectTeardown(self.table.cancel_listen.?, route_id, "cancel_listen");
    }

    fn localLocatorOutcome(
        ctx: *anyopaque,
        listener_ctx: *anyopaque,
        transport: []const u8,
        allocator: std.mem.Allocator,
    ) net.netlayer.ListenerLocatorOutcome {
        const self = of(ctx);
        return (provider_locator.Listener{
            .ctx = listener_ctx,
            .transport = transport,
            .local = self.table.listener_locator.?,
            .canonicalize = self.table.listener_advertise.?,
        }).localLocatorOutcome(allocator);
    }

    fn canonicalizeLocatorOutcome(
        ctx: *anyopaque,
        listener_ctx: *anyopaque,
        transport: []const u8,
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) net.netlayer.ListenerLocatorOutcome {
        const self = of(ctx);
        return (provider_locator.Listener{
            .ctx = listener_ctx,
            .transport = transport,
            .local = self.table.listener_locator.?,
            .canonicalize = self.table.listener_advertise.?,
        }).canonicalizeLocatorOutcome(allocator, locator);
    }

    fn listenerRestorationStateOutcome(
        ctx: *anyopaque,
        listener_ctx: *anyopaque,
        out: []u8,
    ) net.netlayer.ListenerRestorationOutcome {
        const self = of(ctx);
        return listenerRestorationOutcome(
            self.owner,
            self.table.listener_restoration_state.?,
            listener_ctx,
            out,
        );
    }

    fn finishAcceptOutcome(ctx: *anyopaque, listener_ctx: *anyopaque) net.multiplexed_resident.MultiplexedResident.RawFinishAcceptOutcome {
        const self = of(ctx);
        var conn: u64 = 0;
        var report = std.mem.zeroes(shared.PancakeProviderFailure);
        const code = self.table.finish_accept.?(listener_ctx, &conn, &report);
        if (code == PANCAKE_OK or code == PANCAKE_ERR_WOULD_BLOCK) {
            if (!providerFailureIsEmpty(report)) {
                self.failContract(if (code == PANCAKE_OK)
                    "finish_accept reported failure on success"
                else
                    "finish_accept reported failure while blocked");
                const cleanup = if (conn != 0)
                    self.callSubjectTeardown(self.table.conn_close.?, @intCast(conn), "conn_close")
                else
                    null;
                self.owner.retainContradictoryReport(report, cleanup);
                return .{ .failed = .init(error.ConnectionLost) };
            }
            if (code == PANCAKE_ERR_WOULD_BLOCK) {
                if (conn != 0) {
                    self.failContract("finish_accept published a connection while blocked");
                    if (self.callSubjectTeardown(self.table.conn_close.?, @intCast(conn), "conn_close")) |cleanup|
                        self.owner.runtime.noteTerminalOperationFailure(.fromChain(cleanup));
                    return .{ .failed = .init(error.ConnectionLost) };
                }
                return .{ .connection = null };
            }
            return .{ .connection = std.math.cast(usize, conn) orelse {
                self.failContract("finish_accept returned a connection id outside the host range");
                return .{ .failed = .init(error.ConnectionLost) };
            } };
        }
        var chain = failureChainFromProvider(code, report) catch blk: {
            self.failContract("finish_accept returned an invalid failure report");
            break :blk foundation.FailureChain.init(error.ProviderContract);
        };
        if (conn != 0) {
            self.failContract("finish_accept published an output on failure");
            if (self.callSubjectTeardown(self.table.conn_close.?, @intCast(conn), "conn_close")) |cleanup|
                chain.noteChain(cleanup);
            self.owner.runtime.noteTerminalOperationFailure(.fromChain(chain));
        }
        const classification: net.netlayer.AcceptError = if (code == shared.PANCAKE_ERR_INTERNAL) error.OutOfMemory else error.ConnectionLost;
        return .{ .failed = .fromChain(classification, chain) };
    }

    fn stopListen(ctx: *anyopaque, listener_ctx: *anyopaque) net.multiplexed_resident.TeardownOutcome {
        const self = of(ctx);
        return self.callStopListen(listener_ctx);
    }

    fn callStopListen(self: *Adapter, listener_ctx: *anyopaque) net.multiplexed_resident.TeardownOutcome {
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.stop_listen.?(listener_ctx, &report);
        return self.teardownOutcome(code, report, "stop_listen");
    }

    /// A listener handle published while its parent operation is already
    /// failing has no installed readiness route through which a pending stop
    /// could settle. The provider package still joins its task at release,
    /// but returning WOULD_BLOCK here violates the rollback contract and must
    /// remain observable instead of disappearing behind `failure()`.
    fn stopListenRollback(self: *Adapter, listener_ctx: *anyopaque) ?foundation.FailureChain {
        return switch (self.callStopListen(listener_ctx)) {
            .complete => null,
            .failed => |failure| failure,
            .pending => blk: {
                self.failContract("stop_listen returned pending without an installed readiness owner");
                break :blk foundation.FailureChain.init(error.ProviderContract);
            },
        };
    }

    pub fn failContract(self: *Adapter, message: []const u8) void {
        self.owner.failContract(message);
    }

    fn callSubjectTeardown(
        self: *Adapter,
        callback: shared.multiplexed_transport.PancakeMultiplexedSubjectFn,
        subject: usize,
        operation: []const u8,
    ) ?foundation.FailureChain {
        var report = shared.transport_provider.emptyProviderFailure();
        const code = callback(self.table.ctx, @intCast(subject), &report);
        return self.teardownFailure(code, report, operation);
    }

    fn teardownFailure(
        self: *Adapter,
        code: i32,
        report: shared.PancakeProviderFailure,
        operation: []const u8,
    ) ?foundation.FailureChain {
        return teardown.failure(code, report) catch {
            self.failContract(operation);
            return foundation.FailureChain.init(error.ProviderContract);
        };
    }

    pub fn teardownOutcome(
        self: *Adapter,
        code: i32,
        report: shared.PancakeProviderFailure,
        operation: []const u8,
    ) net.multiplexed_resident.TeardownOutcome {
        return teardown.outcome(code, report) catch {
            self.failContract(operation);
            return .{ .failed = foundation.FailureChain.init(error.ProviderContract) };
        };
    }
};

pub fn prepare(
    owner: *Owner,
    table_ptr: *const shared.PancakeMultiplexedTransport,
) !*Adapter {
    try validation.tablePrefix(shared.PancakeMultiplexedTransport, table_ptr, shared.multiplexed_transport.PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION, "multiplexed");
    const table = table_ptr.*;
    if (table.readiness_fd == null or table.drain_ready == null or table.try_read == null or
        table.try_write == null or table.conn_close == null or table.conn_take_failure == null or table.conn_remote_key == null)
    {
        shared.setLastError("driver: multiplexed provider readiness and connection callbacks must be set", .{});
        return error.InvalidArgument;
    }
    const dial_any = table.start_connect != null or table.finish_connect != null or table.cancel_connect != null;
    const dial = try validation.operationGroup(dial_any, table.start_connect != null and
        table.finish_connect != null and table.cancel_connect != null, "multiplexed dial");
    const external_claim = table.claim_external != null;
    const listen_completion_any = table.finish_listen != null or table.cancel_listen != null;
    const listen_completion = try validation.operationGroup(
        listen_completion_any,
        table.finish_listen != null and table.cancel_listen != null,
        "multiplexed listen completion",
    );
    const listen_any = table.listen != null or listen_completion_any or
        table.listener_locator != null or
        table.listener_advertise != null or table.listener_restoration_state != null or
        table.finish_accept != null or table.stop_listen != null;
    const listen = try validation.operationGroup(listen_any, table.listen != null and
        table.listener_locator != null and table.listener_advertise != null and
        table.finish_accept != null and table.stop_listen != null, "multiplexed listen");
    if (!dial and !listen and !external_claim) {
        shared.setLastError("driver: multiplexed provider has no operation group", .{});
        return error.InvalidArgument;
    }
    const adapter = try owner.allocator.create(Adapter);
    errdefer owner.allocator.destroy(adapter);
    adapter.* = .{
        .owner = owner,
        .table = table,
        .vtable = .{
            .readiness_fd = Adapter.readinessFd,
            .drain_ready = Adapter.drainReady,
            .dial = if (dial) .{
                .start_connect = Adapter.startConnect,
                .finish_connect = Adapter.finishConnect,
                .cancel_connect = Adapter.cancelConnect,
            } else null,
            .external_claim = if (external_claim) .{
                .claim_external = Adapter.claimExternal,
            } else null,
            .listen = if (listen) .{
                .listen = Adapter.listen,
                .completion = if (listen_completion) .{
                    .finish = Adapter.finishListen,
                    .cancel = Adapter.cancelListen,
                } else null,
                .local_locator = Adapter.localLocatorOutcome,
                .canonicalize_locator = Adapter.canonicalizeLocatorOutcome,
                .restoration_state = if (table.listener_restoration_state != null) Adapter.listenerRestorationStateOutcome else null,
                .finish_accept = Adapter.finishAcceptOutcome,
                .stop_listen = Adapter.stopListen,
            } else null,
            .try_read = connection_io.tryRead,
            .try_write = connection_io.tryWrite,
            .take_failure = connection_io.takeFailure,
            .conn_close = connection_io.close,
            .conn_remote_key = connection_io.remoteKey,
        },
    };
    return adapter;
}
