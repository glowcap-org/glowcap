//! A C stream provider table as the completion loop's foreign provider
//! (`net.external_completion`, ADR-0018).
//!
//! Each verb calls the table once and checks its outputs against the stream
//! contract in `c_abi/shared/transport_provider.zig`. A provider that breaks
//! the contract is reported to `Sink.violation` and the verb fails with
//! `ProviderContract`. A teardown failure goes to `Sink.teardown`, because
//! nothing in the loop waits on a release. A completion carries one error, so
//! a failure reaches the loop as its chain's primary cause.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");
const shared = @import("c_abi_shared");
const owner_mod = @import("owner.zig");
const validation = @import("validation.zig");
const provider_locator = @import("../provider_locator.zig");

const external = net.external_completion;
const crypto = foundation.crypto;
const LocatorProjection = shared.locator_adapter.Projection;
const GLOWCAP_OK = shared.GLOWCAP_OK;

/// Where the adapter reports what no completion can carry.
pub const Sink = struct {
    ctx: *anyopaque,
    violation: *const fn (ctx: *anyopaque, message: []const u8) void,
    teardown: *const fn (ctx: *anyopaque, failure: foundation.FailureChain) void,
};

pub const StreamProvider = struct {
    allocator: std.mem.Allocator,
    transport: []const u8,
    table: shared.GlowcapStreamTransport,
    sink: Sink,

    /// The completion contract for this table. The value borrows `self`,
    /// which outlives every backend that dials through it.
    pub fn provider(self: *StreamProvider) external.Provider {
        return .{
            .transport = self.transport,
            .ctx = self,
            .vtable = if (self.table.listen != null) &listening_vtable else &dial_vtable,
        };
    }

    const dial_vtable = external.VTable{
        .start_connect = startConnect,
        .finish_connect = finishConnect,
        .cancel_connect = cancelConnect,
        .try_read = tryRead,
        .try_write = tryWrite,
        .conn_take_failure = connTakeFailure,
        .conn_close = connClose,
    };

    const listening_vtable = blk: {
        var vtable = dial_vtable;
        vtable.listen = listen;
        vtable.finish_listen = finishListen;
        vtable.cancel_listen = cancelListen;
        vtable.accept = accept;
        vtable.listener_close = listenerClose;
        vtable.listener_locator = listenerLocator;
        vtable.listener_canonicalize = listenerCanonicalize;
        vtable.listener_restoration_state = listenerRestorationState;
        break :blk vtable;
    };

    fn of(ctx: *anyopaque) *StreamProvider {
        return @ptrCast(@alignCast(ctx));
    }

    fn startConnect(ctx: *anyopaque, locator: model.PeerLocator) external.Started {
        const self = of(ctx);
        // A listen-only table has no dial group.
        if (self.table.start_connect == null) return .{ .failed = error.OperationUnsupported };
        var hint_stack: [shared.locator_adapter.inline_hint_capacity]shared.GlowcapLocatorHintView = undefined;
        var projection = LocatorProjection.init(self.allocator, locator, &hint_stack) catch |err|
            return .{ .failed = err };
        defer projection.deinit(self.allocator);
        var attempt: ?*anyopaque = null;
        var fd: i32 = -1;
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.start_connect.?(self.table.ctx, &projection.view, null, &attempt, &fd, &report);
        if (code != GLOWCAP_OK) {
            if (attempt) |handle| {
                self.sink.violation(self.sink.ctx, "stream connect start published outputs on failure");
                cancelConnect(ctx, handle);
            }
            return .{ .failed = self.dialCause(code, report, "stream connect start") };
        }
        const handle = self.checkedHandle(report, attempt, fd, "stream connect start") orelse {
            if (attempt) |orphan| cancelConnect(ctx, orphan);
            return .{ .failed = error.ProviderContract };
        };
        return .{ .pending = handle };
    }

    fn finishConnect(ctx: *anyopaque, attempt: *anyopaque) external.Finished {
        const self = of(ctx);
        var conn: ?*anyopaque = null;
        var fd: i32 = -1;
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.finish_connect.?(attempt, &conn, &fd, &report);
        if (code != GLOWCAP_OK) return .{ .failed = self.dialCause(code, report, "stream connect finish") };
        const handle = self.checkedHandle(report, conn, fd, "stream connect finish") orelse {
            if (conn) |orphan| connClose(ctx, orphan);
            return .{ .failed = error.ProviderContract };
        };
        return .{ .ready = handle };
    }

    fn cancelConnect(ctx: *anyopaque, attempt: *anyopaque) void {
        const self = of(ctx);
        var report = shared.transport_provider.emptyProviderFailure();
        self.released(self.table.cancel_connect.?(attempt, &report), report, "stream connect cancel");
    }

    fn listen(ctx: *anyopaque, designator: []const u8, identity: ?crypto.PeerKey) external.Started {
        const self = of(ctx);
        var identity_storage: [crypto.PeerKey.designator_len]u8 = undefined;
        const identity_designator: []const u8 = if (identity) |key| blk: {
            identity_storage = key.toDesignator();
            break :blk &identity_storage;
        } else &.{};
        var result = validation.emptyListenResult();
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.listen.?(
            self.table.ctx,
            designator.ptr,
            designator.len,
            identity_designator.ptr,
            identity_designator.len,
            null,
            &result,
            &report,
        );
        if (code != GLOWCAP_OK) {
            if (!validation.listenResultUntouched(result))
                self.sink.violation(self.sink.ctx, "stream listen published outputs on failure");
            return .{ .failed = self.cause(code, report, "stream listen") };
        }
        switch (result.state) {
            shared.GLOWCAP_LISTEN_READY => {
                const listener = self.checkedHandle(report, result.listener, null, "stream listen") orelse
                    return .{ .failed = error.ProviderContract };
                return .{ .ready = self.listening(listener.ptr) orelse return .{ .failed = error.ProviderContract } };
            },
            shared.GLOWCAP_LISTEN_PENDING => {
                if (self.table.finish_listen == null) {
                    self.sink.violation(self.sink.ctx, "stream listen returned PENDING without a completion pair");
                    return .{ .failed = error.ProviderContract };
                }
                const attempt = self.checkedHandle(report, result.attempt, result.readiness_fd, "stream listen") orelse
                    return .{ .failed = error.ProviderContract };
                return .{ .pending = attempt };
            },
            else => {
                self.sink.violation(self.sink.ctx, "stream listen returned an unknown state");
                return .{ .failed = error.ProviderContract };
            },
        }
    }

    fn finishListen(ctx: *anyopaque, attempt: *anyopaque) external.Finished {
        const self = of(ctx);
        var listener: ?*anyopaque = null;
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.finish_listen.?(attempt, &listener, &report);
        if (code != GLOWCAP_OK) return .{ .failed = self.cause(code, report, "stream listen finish") };
        const handle = self.checkedHandle(report, listener, null, "stream listen finish") orelse
            return .{ .failed = error.ProviderContract };
        return .{ .ready = self.listening(handle.ptr) orelse return .{ .failed = error.ProviderContract } };
    }

    fn cancelListen(ctx: *anyopaque, attempt: *anyopaque) void {
        const self = of(ctx);
        var report = shared.transport_provider.emptyProviderFailure();
        self.released(self.table.cancel_listen.?(attempt, &report), report, "stream listen cancel");
    }

    fn accept(ctx: *anyopaque, listener: *anyopaque) external.Finished {
        const self = of(ctx);
        var conn: ?*anyopaque = null;
        var fd: i32 = -1;
        var report = shared.transport_provider.emptyProviderFailure();
        const code = self.table.accept.?(self.table.ctx, listener, &conn, &fd, &report);
        if (code != GLOWCAP_OK) return .{ .failed = self.cause(code, report, "stream accept") };
        const handle = self.checkedHandle(report, conn, fd, "stream accept") orelse {
            if (conn) |orphan| connClose(ctx, orphan);
            return .{ .failed = error.ProviderContract };
        };
        return .{ .ready = handle };
    }

    fn listenerClose(ctx: *anyopaque, listener: *anyopaque) void {
        const self = of(ctx);
        var report = shared.transport_provider.emptyProviderFailure();
        self.released(self.table.listener_close.?(self.table.ctx, listener, &report), report, "stream listener close");
    }

    fn listenerLocator(ctx: *anyopaque, listener: *anyopaque, allocator: std.mem.Allocator) anyerror!model.PeerLocator {
        const self = of(ctx);
        const outcome = (provider_locator.Listener{
            .ctx = listener,
            .transport = self.transport,
            .local = self.table.listener_locator.?,
            .canonicalize = self.table.listener_advertise.?,
        }).localLocatorOutcome(allocator);
        return switch (outcome) {
            .locator => |locator| locator,
            // One error crosses the completion contract: keep the
            // listener failure's classification rather than its raw cause.
            .failed => |failure| net.netlayer.projectListenError(failure),
        };
    }

    fn listenerCanonicalize(
        ctx: *anyopaque,
        listener: *anyopaque,
        allocator: std.mem.Allocator,
        candidate: model.PeerLocator,
    ) anyerror!model.PeerLocator {
        const self = of(ctx);
        const outcome = (provider_locator.Listener{
            .ctx = listener,
            .transport = self.transport,
            .local = self.table.listener_locator.?,
            .canonicalize = self.table.listener_advertise.?,
        }).canonicalizeLocatorOutcome(allocator, candidate);
        return switch (outcome) {
            .locator => |locator| locator,
            // One error crosses the completion contract: keep the
            // listener failure's classification rather than its raw cause.
            .failed => |failure| net.netlayer.projectListenError(failure),
        };
    }

    /// The table's restoration query, held to the stream contract: a
    /// completed query reports no failure, and a failed one publishes no size.
    fn listenerRestorationState(ctx: *anyopaque, listener: *anyopaque, out: []u8) net.netlayer.ListenerRestorationOutcome {
        const self = of(ctx);
        const query = self.table.listener_restoration_state orelse return .unsupported;
        var needed: usize = 0;
        var report = shared.transport_provider.emptyProviderFailure();
        const code = query(listener, if (out.len == 0) null else out.ptr, out.len, &needed, &report);
        const completed = (code == GLOWCAP_OK and needed <= out.len) or
            (code == shared.GLOWCAP_ERR_BUFFER_TOO_SMALL and needed > out.len);
        if (completed) {
            if (owner_mod.providerFailureIsEmpty(report)) return .{ .size = needed };
            self.sink.violation(self.sink.ctx, "listener restoration state reported failure data on success");
            return .{ .failed = .init(error.ProviderContract) };
        }
        const failure = owner_mod.failureChainFromProvider(code, report) catch {
            self.sink.violation(self.sink.ctx, "listener restoration state returned an invalid structured failure");
            return .{ .failed = .init(error.ProviderContract) };
        };
        if (needed != 0) self.sink.violation(self.sink.ctx, "listener restoration state published a size on failure");
        return .{ .failed = failure };
    }

    fn tryRead(ctx: *anyopaque, conn: *anyopaque, buf: []u8) net.completion.TryRead {
        const self = of(ctx);
        const got = self.table.try_read.?(self.table.ctx, conn, buf.ptr, buf.len);
        if (!validation.tryIoResultValid(got, buf.len)) {
            self.sink.violation(self.sink.ctx, "stream try_read returned an invalid result");
            return .{ .failed = error.ProviderContract };
        }
        if (got == shared.GLOWCAP_TRANSPORT_WOULD_BLOCK) return .would_block;
        if (got == 0) return .closed;
        // The connection's report stays with the table until the runtime
        // claims it through `conn_take_failure`.
        if (got < 0) return .{ .failed = error.ReadFailed };
        return .{ .transferred = @intCast(got) };
    }

    fn tryWrite(ctx: *anyopaque, conn: *anyopaque, bytes: []const u8) net.completion.TryWrite {
        const self = of(ctx);
        const wrote = self.table.try_write.?(self.table.ctx, conn, bytes.ptr, bytes.len);
        if (!validation.tryIoResultValid(wrote, bytes.len)) {
            self.sink.violation(self.sink.ctx, "stream try_write returned an invalid result");
            return .{ .failed = error.ProviderContract };
        }
        if (wrote == shared.GLOWCAP_TRANSPORT_WOULD_BLOCK or wrote == 0) return .would_block;
        if (wrote < 0) return .{ .failed = error.WriteFailed };
        return .{ .transferred = @intCast(wrote) };
    }

    fn connClose(ctx: *anyopaque, conn: *anyopaque) void {
        const self = of(ctx);
        var report = shared.transport_provider.emptyProviderFailure();
        self.released(self.table.conn_close.?(self.table.ctx, conn, &report), report, "stream close");
    }

    /// A successful handle-producing call: an empty report, a handle, and a
    /// descriptor. A listener passes a null `fd` and reports its descriptor
    /// through `listening`.
    fn checkedHandle(
        self: *StreamProvider,
        report: shared.GlowcapProviderFailure,
        ptr: ?*anyopaque,
        fd: ?i32,
        comptime what: []const u8,
    ) ?external.Handle {
        if (!owner_mod.providerFailureIsEmpty(report)) {
            self.sink.violation(self.sink.ctx, what ++ " reported failure data on success");
            return null;
        }
        const owned = ptr orelse {
            self.sink.violation(self.sink.ctx, what ++ " succeeded without a handle");
            return null;
        };
        const descriptor = fd orelse return .{ .ptr = owned, .fd = -1 };
        if (descriptor < 0) {
            self.sink.violation(self.sink.ctx, what ++ " succeeded without a readiness descriptor");
            return null;
        }
        return .{ .ptr = owned, .fd = descriptor };
    }

    fn listening(self: *StreamProvider, listener: *anyopaque) ?external.Handle {
        const fd = self.table.listener_readiness_fd.?(self.table.ctx, listener);
        if (fd >= 0) return .{ .ptr = listener, .fd = fd };
        self.sink.violation(self.sink.ctx, "stream listener has no readiness descriptor");
        listenerClose(self, listener);
        return null;
    }

    fn cause(
        self: *StreamProvider,
        code: i32,
        report: shared.GlowcapProviderFailure,
        comptime what: []const u8,
    ) anyerror {
        const chain = owner_mod.failureChainFromProvider(code, report) catch {
            self.sink.violation(self.sink.ctx, what ++ " returned an invalid structured failure");
            return error.ProviderContract;
        };
        return chain.cause;
    }

    /// A dial verb's failure reaches the completion resident as one scalar
    /// error, which it classifies on the `DialError` retry axis. The status
    /// proxy error (`ProviderIo` and its siblings) sits outside that axis and
    /// would read as a transient lost connection, so the scalar is the
    /// classification the report names or its status code implies.
    fn dialCause(
        self: *StreamProvider,
        code: i32,
        report: shared.GlowcapProviderFailure,
        comptime what: []const u8,
    ) anyerror {
        const chain = owner_mod.failureChainFromProvider(code, report) catch {
            self.sink.violation(self.sink.ctx, what ++ " returned an invalid structured failure");
            return error.ProviderContract;
        };
        return owner_mod.dialErrorFromProvider(code, chain.cause_name);
    }

    fn connTakeFailure(ctx: *anyopaque, conn: *anyopaque) ?foundation.FailureChain {
        const self = of(ctx);
        var report = std.mem.zeroes(shared.GlowcapProviderFailure);
        self.table.conn_take_failure.?(self.table.ctx, conn, &report);
        if (owner_mod.providerFailureIsEmpty(report)) return null;
        return owner_mod.failureChainFromProvider(report.result, report) catch {
            self.sink.violation(self.sink.ctx, "stream conn_take_failure returned an invalid report");
            return .init(error.ProviderContract);
        };
    }

    fn released(self: *StreamProvider, code: i32, report: shared.GlowcapProviderFailure, comptime what: []const u8) void {
        if (code == GLOWCAP_OK) {
            if (!owner_mod.providerFailureIsEmpty(report))
                self.sink.violation(self.sink.ctx, what ++ " reported failure data on success");
            return;
        }
        const chain = owner_mod.failureChainFromProvider(code, report) catch {
            self.sink.violation(self.sink.ctx, what ++ " returned an invalid structured failure");
            return;
        };
        self.sink.teardown(self.sink.ctx, chain);
    }
};
