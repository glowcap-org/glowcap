//! A foreign provider's failed listen keeps its exact chain on the external
//! completion backend. A refused open answers until the next open, and a
//! listener whose finish failed answers until it is closed, so a chain never
//! describes another attempt.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const net = glowcap.net;
const external = net.external_completion;

const Backend = external.CompletionBackend(net.Backend);

const transport = "fake-stream";
const named: foundation.FailureChain = .{
    .cause = error.ProviderIo,
    .cause_name = "AddressInUse",
    .classification = .io,
};

/// A provider whose listen answers from a script and whose descriptor is a
/// wake channel the test nudges to finish a pending attempt.
const Script = struct {
    wake: net.wake_channel.WakeChannel,
    start: external.ListenStarted,
    finish: external.ListenFinished,
    listen_calls: usize = 0,
    cancel_calls: usize = 0,
    close_calls: usize = 0,

    fn of(ctx: *anyopaque) *Script {
        return @ptrCast(@alignCast(ctx));
    }

    fn listen(ctx: *anyopaque, _: []const u8, _: ?foundation.crypto.PeerKey) external.ListenStarted {
        const self = of(ctx);
        self.listen_calls += 1;
        return self.start;
    }

    fn finishListen(ctx: *anyopaque, _: *anyopaque) external.ListenFinished {
        return of(ctx).finish;
    }

    fn cancelListen(ctx: *anyopaque, _: *anyopaque) void {
        of(ctx).cancel_calls += 1;
    }

    fn listenerClose(ctx: *anyopaque, _: *anyopaque) void {
        of(ctx).close_calls += 1;
    }

    fn unreachableConnect(_: *anyopaque, _: model.PeerLocator) external.Started {
        unreachable;
    }

    fn unreachableFinish(_: *anyopaque, _: *anyopaque) external.Finished {
        unreachable;
    }

    fn unreachableCancel(_: *anyopaque, _: *anyopaque) void {
        unreachable;
    }

    fn unreachableRead(_: *anyopaque, _: *anyopaque, _: []u8) net.completion.TryRead {
        unreachable;
    }

    fn unreachableWrite(_: *anyopaque, _: *anyopaque, _: []const u8) net.completion.TryWrite {
        unreachable;
    }

    fn unreachableClose(_: *anyopaque, _: *anyopaque) void {
        unreachable;
    }

    const vtable: external.VTable = .{
        .start_connect = unreachableConnect,
        .finish_connect = unreachableFinish,
        .cancel_connect = unreachableCancel,
        .listen = listen,
        .finish_listen = finishListen,
        .cancel_listen = cancelListen,
        .listener_close = listenerClose,
        .try_read = unreachableRead,
        .try_write = unreachableWrite,
        .conn_close = unreachableClose,
    };

    fn provider(self: *Script) external.Provider {
        return .{ .transport = transport, .ctx = self, .vtable = &vtable };
    }

    fn handle(self: *Script) external.Handle {
        return .{ .ptr = self, .fd = self.wake.read };
    }
};

const target: Backend.ListenTarget = .{ .provider = .{ .transport = transport, .designator = "endpoint" } };

fn expectNamed(chain: ?foundation.FailureChain) !void {
    const got = chain orelse return error.NoChain;
    try std.testing.expectEqualStrings("AddressInUse", got.primaryName());
    try std.testing.expectEqual(error.ProviderIo, got.cause);
}

fn newBackend(providers: []const external.Provider) !Backend {
    const allocator = std.testing.allocator;
    return Backend.initWithPlatform(allocator, .{ .providers = providers }, try net.Backend.init(allocator, 8, 2, 256), 2, 256);
}

const none: ?foundation.FailureChain = null;

fn newScript(start: external.ListenStarted) !Script {
    return .{ .wake = try net.wake_channel.WakeChannel.open(), .start = start, .finish = .{ .failed = named } };
}

/// The one completion the backend owes, within five seconds.
fn nextCompletion(backend: *Backend) !net.completion.Completion {
    var out: [4]net.completion.Completion = undefined;
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        const n = try backend.poll(&out, 10);
        if (n == 0) continue;
        try std.testing.expectEqual(@as(usize, 1), n);
        return out[0];
    }
    return error.CompletionTimedOut;
}

test "a refused provider listen answers with its chain until the next open" {
    if (!(builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin())) return error.SkipZigTest;
    var script = try newScript(.{ .failed = named });
    defer script.wake.deinit();
    const providers = [_]external.Provider{script.provider()};
    var backend = try newBackend(&providers);
    defer backend.deinit();

    try std.testing.expectError(error.ProviderIo, backend.openListener(target));
    try expectNamed(backend.listenFailure(null));

    script.start = .{ .ready = script.handle() };
    const fd = try backend.openListener(target);
    try std.testing.expectEqual(none, backend.listenFailure(null));
    try std.testing.expectEqual(none, backend.listenFailure(fd));

    // The backend refuses a second listener itself, so no provider chain exists.
    try std.testing.expectError(error.AddressInUse, backend.openListener(target));
    try std.testing.expectEqual(none, backend.listenFailure(null));
    try std.testing.expectEqual(@as(usize, 2), script.listen_calls);

    try backend.submitClose(9, fd);
    try std.testing.expectEqual(@as(u64, 9), (try nextCompletion(&backend)).user_data);
    try std.testing.expectEqual(@as(usize, 1), script.close_calls);
}

test "a listener whose finish failed holds its chain and its seat until it is closed" {
    if (!(builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin())) return error.SkipZigTest;
    var script = try newScript(undefined);
    defer script.wake.deinit();
    script.start = .{ .pending = script.handle() };
    const providers = [_]external.Provider{script.provider()};
    var backend = try newBackend(&providers);
    defer backend.deinit();

    const fd = try backend.openListener(target);
    try std.testing.expect(backend.listenerPending(fd));
    try backend.submitListenReady(7, fd);
    _ = try script.wake.nudge();

    const failed = try nextCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 7), failed.user_data);
    try std.testing.expect(failed.result < 0);
    try std.testing.expectEqual(error.ProviderIo, failed.failure.?);
    try std.testing.expect(!backend.listenerPending(fd));
    try expectNamed(backend.listenFailure(fd));
    // Another listener's descriptor and a refused open are different failures.
    try std.testing.expectEqual(none, backend.listenFailure(fd + 1));
    try std.testing.expectEqual(none, backend.listenFailure(null));

    // A listen that arrives before the failed one is closed finds the seat
    // taken, reaches no provider, and leaves the chain where it was.
    try std.testing.expectError(error.AddressInUse, backend.openListener(target));
    try std.testing.expectEqual(@as(usize, 1), script.listen_calls);
    try expectNamed(backend.listenFailure(fd));
    try std.testing.expectError(error.ListenerClosed, backend.submitAccept(8, fd));
    // A late setup wait learns the same failure.
    try backend.submitListenReady(11, fd);
    const late = try nextCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 11), late.user_data);
    try std.testing.expectEqual(error.ProviderIo, late.failure.?);

    try backend.submitClose(9, fd);
    try std.testing.expectEqual(@as(u64, 9), (try nextCompletion(&backend)).user_data);
    try std.testing.expectEqual(none, backend.listenFailure(fd));
    // The provider consumed the attempt when its finish refused.
    try std.testing.expectEqual(@as(usize, 0), script.cancel_calls);

    script.start = .{ .ready = script.handle() };
    const reopened = try backend.openListener(target);
    try backend.submitClose(10, reopened);
    try std.testing.expectEqual(@as(u64, 10), (try nextCompletion(&backend)).user_data);
}

test "releasing a listener whose finish failed frees its seat without a provider verb" {
    if (!(builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin())) return error.SkipZigTest;
    var script = try newScript(undefined);
    defer script.wake.deinit();
    script.start = .{ .pending = script.handle() };
    const providers = [_]external.Provider{script.provider()};
    var backend = try newBackend(&providers);
    // The backend asserts at deinit that no listener row remains.
    defer backend.deinit();

    const fd = try backend.openListener(target);
    try backend.submitListenReady(7, fd);
    _ = try script.wake.nudge();
    try std.testing.expect((try nextCompletion(&backend)).result < 0);

    backend.closeFd(fd);
    try std.testing.expectEqual(none, backend.listenFailure(fd));
    try std.testing.expectEqual(@as(usize, 0), script.cancel_calls);
    try std.testing.expectEqual(@as(usize, 0), script.close_calls);
}
