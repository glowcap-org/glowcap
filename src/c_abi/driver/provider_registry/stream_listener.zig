//! Own stream-provider listener admission, readiness, acceptance, and teardown.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const net = @import("net");
const stream = @import("stream.zig");
const provider_locator = @import("../provider_locator.zig");
const teardown = @import("teardown.zig");
const validation = @import("validation.zig");
const driver_error = @import("../error.zig");
const owner_mod = @import("owner.zig");
const shared = @import("c_abi_shared");

const crypto = foundation.crypto;
const Adapter = stream.Adapter;
const listenerRestorationOutcome = owner_mod.listenerRestorationOutcome;
const failureChainFromProvider = owner_mod.failureChainFromProvider;
const providerFailureIsEmpty = owner_mod.providerFailureIsEmpty;
const GLOWCAP_OK = shared.GLOWCAP_OK;
const GLOWCAP_ERR_WOULD_BLOCK = shared.GLOWCAP_ERR_WOULD_BLOCK;

const ListenerBox = struct {
    adapter: *Adapter,
    handle: *anyopaque,
};

fn of(ctx: *anyopaque) *Adapter {
    return @ptrCast(@alignCast(ctx));
}

fn closeListenerHandle(self: *Adapter, handle: *anyopaque) ?net.netlayer.ListenerCloseFailure {
    var report = shared.transport_provider.emptyProviderFailure();
    const code = self.table.listener_close.?(self.table.ctx, handle, &report);
    if (code == GLOWCAP_OK) {
        if (providerFailureIsEmpty(report)) return null;
        self.owner.failContract("stream listener close reported failure data on success");
        self.owner.retainContradictoryReport(report, null);
        return .init(error.ProviderContract);
    }
    return failureChainFromProvider(code, report) catch {
        self.owner.failContract("stream listener close returned an invalid structured failure");
        return .init(error.ProviderContract);
    };
}

fn makeListener(
    self: *Adapter,
    allocator: std.mem.Allocator,
    handle: *anyopaque,
) net.netlayer.ListenFinishOutcome {
    const box = allocator.create(ListenerBox) catch |err| {
        var failure = net.netlayer.ListenFailure.init(err);
        if (closeListenerHandle(self, handle)) |cleanup| failure.noteChain(cleanup);
        return .{ .failed = failure };
    };
    box.* = .{ .adapter = self, .handle = handle };
    return .{ .ready = .{ .ctx = box, .vtable = &self.listener_vtable } };
}

pub fn listen(
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
    var result = validation.emptyListenResult();
    var report = shared.transport_provider.emptyProviderFailure();
    var options_storage: shared.GlowcapTransportOperationOptions = undefined;
    const code = self.table.listen.?(
        self.table.ctx,
        config.designator.ptr,
        config.designator.len,
        identity.ptr,
        identity.len,
        validation.projectOperationOptions(config.options, &options_storage),
        &result,
        &report,
    );
    if (code == GLOWCAP_OK and !providerFailureIsEmpty(report)) {
        var failure = net.netlayer.ListenFailure.init(error.ProviderContract);
        var cleanup_chain: ?foundation.FailureChain = null;
        if (result.listener) |listener| {
            if (closeListenerHandle(self, listener)) |cleanup| {
                failure.noteChain(cleanup);
                teardown.append(&cleanup_chain, cleanup);
            }
        }
        if (result.attempt) |attempt| if (cancelListenHandle(self, attempt)) |cleanup| {
            failure.noteChain(cleanup);
            teardown.append(&cleanup_chain, cleanup);
        };
        self.owner.failContract("stream listen reported failure data on success");
        self.owner.retainContradictoryReport(report, cleanup_chain);
        return .{ .failed = failure };
    }
    if (code != GLOWCAP_OK) {
        var failure = failureChainFromProvider(code, report) catch blk: {
            self.owner.failContract("stream listen returned an invalid structured failure");
            break :blk net.netlayer.ListenFailure.init(error.ProviderContract);
        };
        if (result.listener) |listener| {
            if (closeListenerHandle(self, listener)) |cleanup| failure.noteChain(cleanup);
        }
        if (result.attempt) |attempt| if (cancelListenHandle(self, attempt)) |cleanup| failure.noteChain(cleanup);
        if (!validation.listenResultUntouched(result)) {
            self.owner.failContract("stream listen published outputs on failure");
            self.owner.runtime.noteTerminalOperationFailure(.fromChain(failure));
        }
        return .{ .failed = failure };
    }
    return switch (result.state) {
        shared.GLOWCAP_LISTEN_READY => blk: {
            const listener = result.listener orelse {
                var failure = net.netlayer.ListenFailure.init(error.BindFailed);
                if (result.attempt) |attempt| {
                    if (cancelListenHandle(self, attempt)) |cleanup| failure.noteChain(cleanup);
                }
                self.owner.failContract("ready stream listen returned no listener");
                return .{ .failed = failure };
            };
            if (result.attempt != null or result.readiness_fd != -1) {
                var failure = net.netlayer.ListenFailure.init(error.BindFailed);
                if (closeListenerHandle(self, listener)) |cleanup| failure.noteChain(cleanup);
                if (result.attempt) |attempt| {
                    if (cancelListenHandle(self, attempt)) |cleanup| failure.noteChain(cleanup);
                }
                self.owner.failContract("ready stream listener returned pending-operation fields");
                return .{ .failed = failure };
            }
            break :blk switch (makeListener(self, allocator, listener)) {
                .ready => |ready| .{ .admitted = .{ .ready = ready } },
                .failed => |failure| .{ .failed = failure },
            };
        },
        shared.GLOWCAP_LISTEN_PENDING => blk: {
            const attempt = result.attempt orelse {
                var failure = net.netlayer.ListenFailure.init(error.BindFailed);
                if (result.listener) |listener| {
                    if (closeListenerHandle(self, listener)) |cleanup| failure.noteChain(cleanup);
                }
                self.owner.failContract("pending stream listener returned no attempt");
                return .{ .failed = failure };
            };
            if (result.listener != null or result.readiness_fd < 0 or
                self.table.finish_listen == null or self.table.cancel_listen == null)
            {
                var failure = net.netlayer.ListenFailure.init(error.BindFailed);
                if (result.listener) |listener| {
                    if (closeListenerHandle(self, listener)) |cleanup| failure.noteChain(cleanup);
                }
                if (cancelListenHandle(self, attempt)) |cleanup| failure.noteChain(cleanup);
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
                if (closeListenerHandle(self, listener)) |cleanup| failure.noteChain(cleanup);
            }
            if (result.attempt) |attempt| if (cancelListenHandle(self, attempt)) |cleanup| failure.noteChain(cleanup);
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
    if (code == GLOWCAP_OK and !providerFailureIsEmpty(report)) {
        var failure = net.netlayer.ListenFailure.init(error.ProviderContract);
        var cleanup_chain: ?foundation.FailureChain = null;
        if (handle) |listener| {
            if (closeListenerHandle(self, listener)) |cleanup| {
                failure.noteChain(cleanup);
                teardown.append(&cleanup_chain, cleanup);
            }
        }
        self.owner.failContract("stream listener finish reported failure data on success");
        self.owner.retainContradictoryReport(report, cleanup_chain);
        return .{ .failed = failure };
    }
    if (code != GLOWCAP_OK) {
        var failure = failureChainFromProvider(code, report) catch blk: {
            self.owner.failContract("stream listener finish returned an invalid structured failure");
            break :blk net.netlayer.ListenFailure.init(error.ProviderContract);
        };
        if (handle != null) {
            self.owner.failContract("stream listener finish published an output on failure");
            if (closeListenerHandle(self, handle.?)) |cleanup| failure.noteChain(cleanup);
            self.owner.runtime.noteTerminalOperationFailure(.fromChain(failure));
        }
        return .{ .failed = failure };
    }
    const listener_handle = handle orelse {
        self.owner.failContract("stream listener finish succeeded without a listener handle");
        return .{ .failed = .init(error.BindFailed) };
    };
    return makeListener(self, allocator, listener_handle);
}

fn cancelListen(owner: *anyopaque, attempt: *anyopaque) ?net.netlayer.ListenerCloseFailure {
    const self = of(owner);
    return cancelListenHandle(self, attempt);
}

fn cancelListenHandle(self: *Adapter, attempt: *anyopaque) ?foundation.FailureChain {
    const cancel = self.table.cancel_listen orelse return null;
    return self.callStreamCancel(cancel, attempt, "stream cancel_listen");
}

fn listenerOf(ctx: *anyopaque) *ListenerBox {
    return @ptrCast(@alignCast(ctx));
}

fn acceptClassification(code: i32) net.netlayer.AcceptError {
    return switch (code) {
        shared.GLOWCAP_ERR_INTERNAL => error.OutOfMemory,
        else => error.ConnectionLost,
    };
}

pub fn listenerAcceptOutcome(ctx: *anyopaque, peer: *engine.Peer, bufs: net.netlayer.Buffers) net.netlayer.AcceptOutcome {
    const box = listenerOf(ctx);
    var handle: ?*anyopaque = null;
    var fd: i32 = -1;
    var report = std.mem.zeroes(shared.GlowcapProviderFailure);
    const code = box.adapter.table.accept.?(
        box.adapter.table.ctx,
        box.handle,
        &handle,
        &fd,
        &report,
    );
    if (code != GLOWCAP_OK) {
        var chain = failureChainFromProvider(code, report) catch blk: {
            box.adapter.owner.failContract("stream accept returned an invalid failure report");
            break :blk foundation.FailureChain.init(error.ProviderContract);
        };
        if (handle != null or fd != -1) {
            box.adapter.owner.failContract("stream accept published outputs on failure");
            if (handle) |conn| if (box.adapter.closeConnection(conn)) |cleanup|
                chain.noteChain(cleanup.toChain());
            box.adapter.owner.runtime.noteTerminalOperationFailure(.fromChain(chain));
        }
        return .{ .failed = .fromChain(acceptClassification(code), chain) };
    }
    if (!providerFailureIsEmpty(report)) {
        box.adapter.owner.failContract("stream accept reported failure on success");
        const cleanup = if (handle) |conn|
            if (box.adapter.closeConnection(conn)) |failure| failure.toChain() else null
        else
            null;
        box.adapter.owner.retainContradictoryReport(report, cleanup);
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
    return switch (box.adapter.makeConnection(peer, bufs, conn, fd)) {
        .connected => |connection| .{ .accepted = connection },
        .failed => |failure| .{ .failed = .fromChain(
            acceptClassification(driver_error.code(failure.kind)),
            failure.toChain(),
        ) },
    };
}

fn listenerWaitOutcome(ctx: *anyopaque, timeout_ms: i32, callback: shared.transport_provider.GlowcapStreamListenerWaitFn) net.netlayer.AcceptReadinessOutcome {
    const box = listenerOf(ctx);
    var report = std.mem.zeroes(shared.GlowcapProviderFailure);
    const code = callback(box.adapter.table.ctx, box.handle, timeout_ms, &report);
    if (code == GLOWCAP_OK or code == GLOWCAP_ERR_WOULD_BLOCK) {
        if (!providerFailureIsEmpty(report)) {
            box.adapter.owner.failContract("stream listener wait reported failure on success");
            box.adapter.owner.retainContradictoryReport(report, null);
            return .{ .failed = .init(error.ConnectionLost) };
        }
        return .{ .ready = code == GLOWCAP_OK };
    }
    const chain = failureChainFromProvider(code, report) catch {
        box.adapter.owner.failContract("stream listener wait returned an invalid failure report");
        return .{ .failed = .init(error.ConnectionLost) };
    };
    return .{ .failed = .fromChain(acceptClassification(code), chain) };
}

pub fn listenerWaitAcceptableOutcome(ctx: *anyopaque, timeout_ms: i32) net.netlayer.AcceptReadinessOutcome {
    const box = listenerOf(ctx);
    return listenerWaitOutcome(ctx, timeout_ms, box.adapter.table.listener_wait_acceptable.?);
}

pub fn localLocatorOutcome(ctx: *anyopaque, allocator: std.mem.Allocator) net.netlayer.ListenerLocatorOutcome {
    const box = listenerOf(ctx);
    return (provider_locator.Listener{
        .ctx = box.handle,
        .transport = box.adapter.transport,
        .local = box.adapter.table.listener_locator.?,
        .canonicalize = box.adapter.table.listener_advertise.?,
    }).localLocatorOutcome(allocator);
}

pub fn canonicalizeLocatorOutcome(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) net.netlayer.ListenerLocatorOutcome {
    const box = listenerOf(ctx);
    return (provider_locator.Listener{
        .ctx = box.handle,
        .transport = box.adapter.transport,
        .local = box.adapter.table.listener_locator.?,
        .canonicalize = box.adapter.table.listener_advertise.?,
    }).canonicalizeLocatorOutcome(allocator, locator);
}

pub fn listenerRestorationStateOutcome(ctx: *anyopaque, out: []u8) net.netlayer.ListenerRestorationOutcome {
    const box = listenerOf(ctx);
    return listenerRestorationOutcome(
        box.adapter.owner,
        box.adapter.table.listener_restoration_state.?,
        box.handle,
        out,
    );
}

pub fn listenerReadinessFd(ctx: *anyopaque) i32 {
    const box = listenerOf(ctx);
    const fd = box.adapter.table.listener_readiness_fd.?(
        box.adapter.table.ctx,
        box.handle,
    );
    if (fd < 0) box.adapter.owner.failContract("stream listener returned an invalid readiness descriptor");
    return fd;
}

pub fn listenerClose(ctx: *anyopaque) ?net.netlayer.ListenerCloseFailure {
    const box = listenerOf(ctx);
    const allocator = box.adapter.owner.allocator;
    const failure = closeListenerHandle(box.adapter, box.handle);
    allocator.destroy(box);
    return failure;
}
