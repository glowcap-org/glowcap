const std = @import("std");
const glowcap = @import("glowcap");
const net = glowcap.net;
const linux = std.os.linux;
const completion = net.completion;

test "Linux completion selection reports implementation and fallback reason" {
    try std.testing.expectEqualStrings(
        "the kernel does not provide the io_uring features glowcap requires",
        net.TcpBackendFallbackReason.io_uring_system_outdated.message(),
    );
    try std.testing.expectEqualStrings(
        "host policy denied io_uring initialization",
        net.TcpBackendFallbackReason.io_uring_permission_denied.message(),
    );
    try std.testing.expectEqualStrings(
        "the kernel rejected io_uring provided-buffer registration",
        net.TcpBackendFallbackReason.provided_buffer_ring_unsupported.message(),
    );
    var backend = try net.Backend.init(std.testing.allocator, 16, 4, 4096);
    defer backend.deinit();

    const status = backend.tcpBackendStatus();
    switch (status.implementation) {
        .io_uring => try std.testing.expectEqual(null, status.fallback_reason),
        .epoll => try std.testing.expect(status.fallback_reason != null),
    }
}

test "Linux completion status survives native loop adapter stacks" {
    const expected = blk: {
        var loop = try net.TcpLoop.initWithBackendOptions(
            std.testing.allocator,
            .{ .queue_entries = 1, .read_buffers = 1, .read_buffer_bytes = 64 },
            unusedMakePeer,
            null,
            .{ .max_conns = 0 },
        );
        defer loop.deinit();
        break :blk net.tcpBackendStatus(&loop);
    };

    var onion = try net.OnionLoop.initWithBackend(
        std.testing.allocator,
        try net.OnionBackend.init(std.testing.allocator, 1, 1, 64),
        unusedMakePeer,
        null,
        .{ .max_conns = 0 },
    );
    defer onion.deinit();
    try std.testing.expectEqualDeep(expected, net.tcpBackendStatus(&onion));

    var relay = try net.KeyedRelayLoop.initWithBackend(
        std.testing.allocator,
        try net.KeyedRelayBackend.init(std.testing.allocator, 1, 1, 64),
        unusedMakePeer,
        null,
        .{ .max_conns = 0 },
    );
    defer relay.deinit();
    try std.testing.expectEqualDeep(expected, net.tcpBackendStatus(&relay));
}

fn unusedMakePeer(_: ?*anyopaque, _: std.mem.Allocator) anyerror!glowcap.Peer {
    return error.Unused;
}

test "Linux completion classifies only io_uring availability failures for fallback" {
    const selector = net.linux_completion_white_box;
    try std.testing.expectEqual(
        net.TcpBackendFallbackReason.io_uring_system_outdated,
        selector.fallbackReasonFor(error.IoUringSystemOutdated).?,
    );
    try std.testing.expectEqual(
        net.TcpBackendFallbackReason.io_uring_permission_denied,
        selector.fallbackReasonFor(error.IoUringInitDenied).?,
    );
    try std.testing.expectEqual(
        net.TcpBackendFallbackReason.provided_buffer_ring_unsupported,
        selector.fallbackReasonFor(error.ProvidedBufferRingUnsupported).?,
    );
    try std.testing.expectEqual(null, selector.fallbackReasonFor(error.SystemOutdated));
    try std.testing.expectEqual(null, selector.fallbackReasonFor(error.PermissionDenied));
    try std.testing.expectEqual(null, selector.fallbackReasonFor(error.ArgumentsInvalid));
    try std.testing.expectEqual(null, selector.fallbackReasonFor(error.OutOfMemory));
    try std.testing.expectEqual(null, selector.fallbackReasonFor(error.SystemResources));
}

test "epoll failed registration leaves no pending operation" {
    const white_box = net.epoll_white_box;
    var backend = try white_box.TestBackend.init(std.testing.allocator, 1, 1, 64);
    defer backend.deinit();

    const fd = try white_box.TestBackend.openSocket();
    backend.closeFd(fd);
    const before = white_box.pendingCount(&backend);
    try std.testing.expectError(error.EpollControlFailed, backend.submitRecv(1, fd));
    try std.testing.expectEqual(before, white_box.pendingCount(&backend));
}

test "epoll preserves its row when post-completion control fails" {
    const white_box = net.epoll_white_box;
    var backend = try white_box.TestBackend.init(std.testing.allocator, 8, 2, 64);
    defer backend.deinit();
    const wake = try net.wake_channel.WakeChannel.open();
    defer wake.deinit();

    try backend.submitRecv(1, wake.read);
    white_box.failNextControl(&backend);
    _ = try wake.nudge();

    var completions: [1]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 1_000));
    backend.recycleBorrowed(completions[0]);
    try std.testing.expectEqual(@as(usize, 1), white_box.pendingCount(&backend));
    try std.testing.expectError(error.EpollControlFailed, backend.poll(&completions, 0));

    // The retained row makes this a MOD, not an ADD that can collide with the
    // still-live kernel registration.
    try backend.submitRecv(2, wake.read);
    _ = try wake.nudge();
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 1_000));
    backend.recycleBorrowed(completions[0]);
    try std.testing.expectEqual(@as(usize, 0), white_box.pendingCount(&backend));
}

test "epoll leaves kernel interests unchanged when readiness does not complete" {
    const white_box = net.epoll_white_box;
    var backend = try white_box.TestBackend.init(std.testing.allocator, 8, 2, 64);
    defer backend.deinit();
    const wake = try net.wake_channel.WakeChannel.open();
    defer wake.deinit();

    try backend.submitRecv(1, wake.read);
    _ = try wake.nudge();
    white_box.deferNextRecv(&backend);
    white_box.failNextControl(&backend);

    var completions: [1]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 1_000));
    try std.testing.expectEqual(@as(usize, 1), white_box.pendingCount(&backend));

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 1_000));
    backend.recycleBorrowed(completions[0]);
    try std.testing.expectEqual(@as(usize, 1), white_box.pendingCount(&backend));
    try std.testing.expectError(error.EpollControlFailed, backend.poll(&completions, 0));
}

test "epoll returns an empty turn when its wait is interrupted" {
    const Backend = net.epoll_white_box.TestBackend;
    var backend = try Backend.init(std.testing.allocator, 8, 2, 64);
    defer backend.deinit();

    const noop = struct {
        fn handle(_: std.posix.SIG) callconv(.c) void {}
    }.handle;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = noop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.USR1, &action, &previous);
    defer std.posix.sigaction(.USR1, &previous, null);

    const target_tid = linux.gettid();
    var waiting = std.atomic.Value(bool).init(false);
    const interrupter = try std.Thread.spawn(.{}, struct {
        fn run(target: linux.pid_t, armed: *const std.atomic.Value(bool)) void {
            while (!armed.load(.acquire)) std.atomic.spinLoopHint();
            const delay: std.posix.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
            std.debug.assert(linux.errno(linux.nanosleep(&delay, null)) == .SUCCESS);
            const result = linux.tgkill(linux.getpid(), target, .USR1);
            std.debug.assert(linux.errno(result) == .SUCCESS);
        }
    }.run, .{ target_tid, &waiting });
    defer interrupter.join();

    var out: [1]completion.Completion = undefined;
    const started = net.clock.nowMonotonicMs();
    waiting.store(true, .release);
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&out, 10_000));
    try std.testing.expect(net.clock.nowMonotonicMs() - started < 5_000);
}

test "epoll preserves simultaneous read and write work across a short output slice" {
    const white_box = net.epoll_white_box;
    var backend = try white_box.TestBackend.init(std.testing.allocator, 8, 2, 64);
    defer backend.deinit();
    const channel = try net.wake_channel.WakeChannel.open();
    defer channel.deinit();

    try backend.submitRecv(1, channel.read);
    try backend.submitSend(2, channel.read, "outbound");
    _ = try channel.nudge();

    var completions: [1]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 1_000));
    try std.testing.expectEqual(@as(u64, 1), completions[0].user_data);
    backend.recycleBorrowed(completions[0]);
    try std.testing.expectEqual(@as(usize, 1), white_box.pendingCount(&backend));

    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 1_000));
    try std.testing.expectEqual(@as(u64, 2), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, "outbound".len), completions[0].result);
    try std.testing.expectEqual(@as(usize, 0), white_box.pendingCount(&backend));
}

test "epoll cancel retires the exact recv and permits fd reuse" {
    const white_box = net.epoll_white_box;
    var backend = try white_box.TestBackend.init(std.testing.allocator, 8, 2, 64);
    defer backend.deinit();
    const channel = try net.wake_channel.WakeChannel.open();
    defer channel.deinit();

    try backend.submitRecv(11, channel.read);
    try std.testing.expectError(error.InvalidCancelTarget, backend.submitCancel(20, 12, channel.read));
    try std.testing.expectEqual(@as(usize, 1), white_box.pendingCount(&backend));
    try backend.submitCancel(21, 11, channel.read);

    var completions: [2]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 2), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 11), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, -1), completions[0].result);
    try std.testing.expectEqual(@as(u64, 21), completions[1].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[1].result);

    try backend.submitRecv(31, channel.read);
    _ = try channel.nudge();
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 1_000));
    try std.testing.expectEqual(@as(u64, 31), completions[0].user_data);
    backend.recycleBorrowed(completions[0]);
    try std.testing.expectEqual(@as(usize, 0), white_box.pendingCount(&backend));
}

test "epoll close retires pending operations before its close completion" {
    const white_box = net.epoll_white_box;
    var backend = try white_box.TestBackend.init(std.testing.allocator, 8, 2, 64);
    defer backend.deinit();
    const channel = try net.wake_channel.WakeChannel.open();
    defer _ = linux.close(channel.write);
    var read_closed_by_backend = false;
    defer {
        if (!read_closed_by_backend) _ = linux.close(channel.read);
    }

    try backend.submitRecv(1, channel.read);
    try backend.submitSend(2, channel.read, "pending");
    try backend.submitClose(3, channel.read);
    read_closed_by_backend = true;

    var completions: [3]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 3), try backend.poll(&completions, 0));
    try std.testing.expectEqual(@as(u64, 1), completions[0].user_data);
    try std.testing.expectEqual(@as(i32, -1), completions[0].result);
    try std.testing.expectEqual(@as(u64, 2), completions[1].user_data);
    try std.testing.expectEqual(@as(i32, -1), completions[1].result);
    try std.testing.expectEqual(@as(u64, 3), completions[2].user_data);
    try std.testing.expectEqual(@as(i32, 0), completions[2].result);
    try std.testing.expectEqual(@as(usize, 0), white_box.pendingCount(&backend));
}

test "epoll pool starvation releases and reuses the exact borrowed buffer" {
    const white_box = net.epoll_white_box;
    var backend = try white_box.TestBackend.init(std.testing.allocator, 8, 1, 64);
    defer backend.deinit();
    const first = try net.wake_channel.WakeChannel.open();
    defer first.deinit();
    const second = try net.wake_channel.WakeChannel.open();
    defer second.deinit();

    try backend.submitRecv(1, first.read);
    try backend.submitRecv(2, second.read);
    _ = try first.nudge();
    _ = try second.nudge();

    var completions: [2]completion.Completion = undefined;
    var completed: usize = 0;
    while (completed < completions.len) {
        const count = try backend.poll(completions[completed..], 1_000);
        if (count == 0) return error.CompletionTimeout;
        completed += count;
    }
    const borrowed = if (completions[0].recv_no_buffer) completions[1] else completions[0];
    const starved = if (completions[0].recv_no_buffer) completions[0] else completions[1];
    try std.testing.expect(!borrowed.recv_no_buffer);
    try std.testing.expect(borrowed.borrowed.kind == .recv);
    try std.testing.expect(starved.recv_no_buffer);
    backend.recycleBorrowed(borrowed);

    const starved_fd = if (starved.user_data == 1) first.read else second.read;
    try backend.submitRecv(3, starved_fd);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 1_000));
    try std.testing.expectEqual(@as(u64, 3), completions[0].user_data);
    try std.testing.expect(completions[0].borrowed.kind == .recv);
    backend.recycleBorrowed(completions[0]);
    try std.testing.expectEqual(@as(usize, 0), white_box.pendingCount(&backend));
}

test "epoll dialed and accepted sockets disable Nagle" {
    const Backend = net.epoll_white_box.TestBackend;
    var backend = try Backend.init(std.testing.allocator, 16, 4, 4096);
    defer backend.deinit();

    const listen_fd = try backend.openListener(0);
    defer backend.closeFd(listen_fd);
    const port = (try backend.listenerAddress(listen_fd)).port;
    try backend.submitAccept(1, listen_fd);

    const dial_fd = try backend.startDial(2, .{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = port,
    } });
    defer backend.closeFd(dial_fd);

    var accepted: ?Backend.Fd = null;
    defer if (accepted) |fd| backend.closeFd(fd);
    var connected = false;
    var rounds: usize = 0;
    while ((accepted == null or !connected) and rounds < 100) : (rounds += 1) {
        var out: [8]completion.Completion = undefined;
        const count = try backend.poll(&out, 100);
        for (out[0..count]) |item| switch (item.user_data) {
            1 => {
                if (item.result < 0) return error.AcceptFailed;
                accepted = item.result;
            },
            2 => {
                if (item.result < 0) return error.ConnectFailed;
                connected = true;
            },
            else => return error.UnexpectedCompletion,
        };
    }
    if (accepted == null or !connected) return error.HandshakeIncomplete;
    try std.testing.expect(nodelayEnabled(dial_fd));
    try std.testing.expect(nodelayEnabled(accepted.?));
}

fn nodelayEnabled(fd: i32) bool {
    var value: u32 = 0;
    var len: u32 = @sizeOf(u32);
    const result = linux.getsockopt(
        fd,
        linux.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&value),
        &len,
    );
    return linux.errno(result) == .SUCCESS and value != 0;
}
