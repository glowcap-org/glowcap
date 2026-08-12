//! The host-wide step surface (ADR-0112): `driver.HostRuntime`, driven the way
//! the driver archive drives it — park on the one aggregate readiness
//! descriptor, call `stepAny` when it reads ready, and hear closures and
//! unobserved completions through the observer seams instead of blocking
//! captures.
//!
//! The headline test serves a whole CapTP conversation with the server never
//! entering a blocking verb after accept: its only pump is
//! poll(readiness descriptor) then `stepAny(0)`, so a wire whose inbound
//! bytes fail to raise the descriptor, or a step that fails to service them,
//! hangs the client's budgeted call and fails the test loudly. The sibling
//! tests pin the seams one by one: the close observer on a partner EOF, the
//! completion sink on a vow nobody parked on, the cross-thread readiness
//! wake, and a sessionless step that parks instead of refusing.
//!
//! The self-wake nudge (`HostRuntime.nudgeIfWorkRemains`) is proven below for
//! a held `feed_tail` of incomplete outer-frame bytes: work no kernel set
//! reports, and the pause shape a step can leave that an embedder must
//! re-enter for. Reader-buffered raw below the kernel's sight shares the
//! same wake path and has no deterministic construction from this tier's
//! public surface; the cross-thread `wakeReadiness` test pins that path.

const std = @import("std");
const pancake = @import("pancake");
const test_host = @import("../support/core_host.zig");
const support_actors = @import("../support/actors.zig");

const model = pancake.ocapn.model;
const driver = pancake.driver;
const driver_core = driver.core;
const net = pancake.net;
const tcp = net.tcp;

const frame_cap = 8192;

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const Treasure = support_actors.StaticReplyValueActor("greet", "hello from the step server");

/// Serve entirely step-shaped: accept one session, publish, then pump
/// nothing but poll(readiness) + `stepAny(0)` until told to stop. The
/// descriptor and the step are the whole loop, exactly the loop-archive
/// contract.
fn stepServe(
    server: *driver.Server,
    ready_fd: i32,
    closed_flag: *std.atomic.Value(bool),
    stop: *std.atomic.Value(bool),
) anyerror!void {
    var observer_ctx = CloseFlag{ .flag = closed_flag };
    server.runtime.setCloseObserver(.{ .ctx = &observer_ctx, .closed = CloseFlag.notify });
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("treasure", Treasure, .{});
    while (!stop.load(.acquire)) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = ready_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, 50) catch return error.PollFailed;
        if (fds[0].revents & std.posix.POLL.IN == 0) continue;
        // Drain to quiet: level-shaped members keep the descriptor readable
        // while anything is pending, so quiet means genuinely serviced.
        while (true) {
            const progress = server.runtime.stepAny(0) catch |err| switch (err) {
                error.ConnectionClosed, error.ProtocolAbort => break,
                else => |e| return e,
            };
            if (progress == null) break;
        }
    }
}

const CloseFlag = struct {
    flag: *std.atomic.Value(bool),
    fn notify(ctx: *anyopaque, session: *driver_core.HostSession) void {
        _ = session;
        const self: *CloseFlag = @ptrCast(@alignCast(ctx));
        self.flag.store(true, .release);
    }
};

test "a server pumped only by the readiness descriptor and stepAny serves a budgeted call, and the close observer hears the hangup" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        opts,
    );
    defer server.close() catch {};
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    const ready_fd = try server.runtime.readinessDescriptor();
    var closed = std.atomic.Value(bool).init(false);
    var stop = std.atomic.Value(bool).init(false);

    var serve_future = try io.concurrent(stepServe, .{ &server, ready_fd, &closed, &stop });
    defer {
        stop.store(true, .release);
        serve_future.await(io) catch {};
    }

    {
        const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
        var designator_buf: [tcp.designator_buf_len]u8 = undefined;
        var client = try driver.connect(
            allocator,
            &netlayers,
            tcp.locator(&designator_buf, address),
            .ephemeral,
            opts,
        );
        defer client.deinit();
        const treasure = try client.fetch("treasure");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const reply = try client.call(treasure, "greet", &.{}, arena.allocator());
        try std.testing.expect(reply == .fulfilled and reply.fulfilled == .string);
        try std.testing.expectEqualStrings("hello from the step server", reply.fulfilled.string);
    }

    // The client hung up. The step loop must observe the EOF and tell the
    // close observer — without any blocking verb running on the server.
    var waited: usize = 0;
    while (!closed.load(.acquire) and waited < 10_000) : (waited += 10) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(closed.load(.acquire));
}

/// A sink that takes exactly the settled/failed completions and remembers
/// what it saw; it owns each taken action and frees it through the core.
const RecordingSink = struct {
    core: *driver_core.Host,
    settled: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn take(ctx: *anyopaque, action: driver_core.HostAction) bool {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        switch (action) {
            .settled => |s| self.settled.store(s.vow_id, .release),
            .failed => |f| self.settled.store(f.vow_id, .release),
            else => return false,
        }
        self.core.freeAction(action);
        return true;
    }
};

test "a vow nobody parked on reaches the completion sink instead of being freed silently" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        opts,
    );
    defer server.close() catch {};
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var stop = std.atomic.Value(bool).init(false);
    var closed = std.atomic.Value(bool).init(false);
    const server_ready = try server.runtime.readinessDescriptor();
    var serve_future = try io.concurrent(stepServe, .{ &server, server_ready, &closed, &stop });
    defer {
        stop.store(true, .release);
        serve_future.await(io) catch {};
    }

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    var client = try driver.connect(
        allocator,
        &netlayers,
        tcp.locator(&designator_buf, address),
        .ephemeral,
        opts,
    );
    defer client.deinit();

    var sink = RecordingSink{ .core = client.runtime.core };
    client.runtime.setCompletionSink(.{ .ctx = &sink, .take = RecordingSink.take });

    // A host-tier vow with no listener — the loop tier's every vow — settles
    // as an action the drain would otherwise free.
    const vow_id = try client.runtime.core.fetch(client.hs, "treasure");

    var waited: usize = 0;
    while (sink.settled.load(.acquire) == 0 and waited < 10_000) : (waited += 1) {
        _ = try client.runtime.stepAny(10);
    }
    try std.testing.expectEqual(vow_id, sink.settled.load(.acquire));
}

/// Records a staged dial's or accept's outcome (`HostRuntime.SessionOpenObserver`).
const DialRecorder = struct {
    opened_session: ?*driver_core.HostSession = null,
    opened_tag: u64 = 0,
    opened_count: usize = 0,
    failed_tag: u64 = 0,
    failed_err: ?anyerror = null,

    fn opened(ctx: *anyopaque, tag: u64, session: *driver_core.HostSession) void {
        const self: *DialRecorder = @ptrCast(@alignCast(ctx));
        self.opened_session = session;
        self.opened_tag = tag;
        self.opened_count += 1;
    }
    fn failed(ctx: *anyopaque, tag: u64, err: anyerror) void {
        const self: *DialRecorder = @ptrCast(@alignCast(ctx));
        self.failed_tag = tag;
        self.failed_err = err;
    }
};

test "blocking opens share the staged-open admission bound" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        opts,
    );
    defer server.close() catch {};
    var address_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var runtime = try driver.HostRuntime.init(allocator, io, &netlayers, .ephemeral, .{
        .frame_cap = frame_cap,
        .max_pending_opens = 1,
        .handshake = .{ .ms = 200 },
        .settle = .{ .ms = 200 },
    });
    defer runtime.deinit();

    var recorder = DialRecorder{};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const locator = tcp.locator(&designator_buf, address);
    try runtime.startConnectLocator(locator, 1, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    try std.testing.expectError(driver.Error.PendingOpenLimitReached, runtime.connectLocator(locator));
    try std.testing.expectError(
        driver.Error.PendingOpenLimitReached,
        runtime.acceptWire(server.listener, server.listener.transportName()),
    );
}

test "a staged dial completes with both ends driven by one thread, and the opened session serves a fetch" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        opts,
    );
    defer server.close() catch {};
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var client_runtime = try driver.HostRuntime.init(allocator, io, &netlayers, .ephemeral, opts);
    defer client_runtime.deinit();
    var recorder = DialRecorder{};

    // Stage the dial and return unopened: the blocking `connectLocator`
    // would park here inside its handshake pump, which no single-thread
    // topology can ever satisfy.
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    try client_runtime.startConnectLocator(tcp.locator(&designator_buf, address), 7, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });
    try std.testing.expect(recorder.opened_session == null);

    // One client step flushes the hello; the blocking accept then completes
    // from bytes already in its socket; the next client steps read the
    // server's hello and report the open through the observer.
    _ = try client_runtime.stepAny(0);
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("treasure", Treasure, .{});

    var rounds: usize = 0;
    while (recorder.opened_session == null and recorder.failed_err == null and rounds < 1_000) : (rounds += 1) {
        _ = try client_runtime.stepAny(10);
        while (try server.runtime.stepAny(0) != null) {}
    }
    try std.testing.expectEqual(@as(?anyerror, null), recorder.failed_err);
    const hs = recorder.opened_session orelse return error.DialNeverOpened;
    try std.testing.expectEqual(@as(u64, 7), recorder.opened_tag);

    // The staged-open session is a full session: a host-tier fetch settles
    // through the completion sink while this same thread steps both ends.
    var sink = RecordingSink{ .core = client_runtime.core };
    client_runtime.setCompletionSink(.{ .ctx = &sink, .take = RecordingSink.take });
    const vow_id = try client_runtime.core.fetch(hs, "treasure");
    var waited: usize = 0;
    while (sink.settled.load(.acquire) == 0 and waited < 1_000) : (waited += 1) {
        _ = try client_runtime.stepAny(10);
        while (try server.runtime.stepAny(0) != null) {}
    }
    try std.testing.expectEqual(vow_id, sink.settled.load(.acquire));
    client_runtime.releaseWire(hs);
}

test "a staged dial against a silent partner fails HandshakeTimedOut on the step's own clock" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    // A listener nobody ever accepts on: the TCP connect succeeds into the
    // backlog and no hello ever answers.
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        opts,
    );
    defer server.close() catch {};
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var client_runtime = try driver.HostRuntime.init(allocator, io, &netlayers, .ephemeral, .{
        .frame_cap = frame_cap,
        .handshake = .{ .ms = 200 },
        .settle = .{ .ms = 200 },
    });
    defer client_runtime.deinit();
    var recorder = DialRecorder{};

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    try client_runtime.startConnectLocator(tcp.locator(&designator_buf, address), 9, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    // Long park timeouts: the staged deadline must clamp the park and wake
    // the step to fail the dial, not wait out the caller's timeout.
    const started_ms = net.clock.nowMs(io);
    var rounds: usize = 0;
    while (recorder.failed_err == null and rounds < 50) : (rounds += 1) {
        _ = try client_runtime.stepAny(5_000);
    }
    const elapsed_ms = net.clock.nowMs(io) - started_ms;
    try std.testing.expectEqual(@as(u64, 9), recorder.failed_tag);
    try std.testing.expectEqual(@as(?anyerror, error.HandshakeTimedOut), recorder.failed_err);
    try std.testing.expect(elapsed_ms < 3_000);
}

test "a wire lost mid-handshake fails the staged dial through the dial observer, not the close observer" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        opts,
    );
    var server_open = true;
    defer if (server_open) server.close() catch {};
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var client_runtime = try driver.HostRuntime.init(allocator, io, &netlayers, .ephemeral, opts);
    defer client_runtime.deinit();
    var recorder = DialRecorder{};
    var closed = std.atomic.Value(bool).init(false);
    var close_flag = CloseFlag{ .flag = &closed };
    client_runtime.setCloseObserver(.{ .ctx = &close_flag, .closed = CloseFlag.notify });

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    try client_runtime.startConnectLocator(tcp.locator(&designator_buf, address), 11, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });
    _ = try client_runtime.stepAny(0);

    // Tearing the listener down resets its never-accepted backlog
    // connection; the pump sees the loss on the next step. The dial path
    // owns the report — a close event would name a session the embedder
    // never received.
    server.close() catch {};
    server_open = false;
    var rounds: usize = 0;
    while (recorder.failed_err == null and rounds < 1_000) : (rounds += 1) {
        _ = try client_runtime.stepAny(10);
    }
    try std.testing.expectEqual(@as(u64, 11), recorder.failed_tag);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionClosed), recorder.failed_err);
    try std.testing.expect(!closed.load(.acquire));
}

test "a silent connector cannot park a staged-accept server: a healthy dial opens and settles beside it on one thread" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    const server_netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};

    // A server built the driver archive's way: a bare listener whose accepts
    // are staged, never pumped.
    var server_runtime = try driver.HostRuntime.init(allocator, io, &server_netlayers, .ephemeral, opts);
    defer server_runtime.deinit();
    var listener = try tcp_resident.netlayer().listen(allocator, .{ .designator = "127.0.0.1:0" });
    defer listener.close();
    try std.testing.expect(try listener.waitReady(5_000));
    const listener_locator = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, listener_locator);
    try server_runtime.core.setAdvertisedLocator(listener_locator);
    try server_runtime.publishGiftable("treasure", Treasure, .{});
    var accepts = DialRecorder{};

    // The silent connector arrives first: a raw TCP stream that never sends
    // a hello. A blocking accept would park the server inside its handshake
    // pump for the whole 10s budget the moment it is accepted.
    const address = try tcp.parseDesignator(listener_locator.designator);
    var silent = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer silent.close(io);

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var client_runtime = try driver.HostRuntime.init(allocator, io, &netlayers, .ephemeral, opts);
    defer client_runtime.deinit();
    var dials = DialRecorder{};
    var sink = RecordingSink{ .core = client_runtime.core };
    client_runtime.setCompletionSink(.{ .ctx = &sink, .take = RecordingSink.take });

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    try client_runtime.startConnectLocator(tcp.locator(&designator_buf, address), 21, .{
        .ctx = &dials,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    var fetch_vow: u64 = 0;
    const started_ms = net.clock.nowMs(io);
    var rounds: usize = 0;
    while (sink.settled.load(.acquire) == 0 and rounds < 1_000) : (rounds += 1) {
        while (listener.waitAcceptable(0) catch false) {
            try server_runtime.startAcceptWire(listener, listener.transportName(), 1, .{
                .ctx = &accepts,
                .opened = DialRecorder.opened,
                .failed = DialRecorder.failed,
            });
        }
        while (try server_runtime.stepAny(0) != null) {}
        _ = try client_runtime.stepAny(10);
        if (dials.opened_session != null and fetch_vow == 0) {
            fetch_vow = try client_runtime.core.fetch(dials.opened_session.?, "treasure");
        }
        try std.testing.expectEqual(@as(?anyerror, null), dials.failed_err);
    }
    const elapsed_ms = net.clock.nowMs(io) - started_ms;

    // The healthy conversation completed promptly — well inside the silent
    // connector's handshake budget, which a blocking accept would have spent
    // parked — and only the healthy accept opened.
    try std.testing.expectEqual(fetch_vow, sink.settled.load(.acquire));
    try std.testing.expect(fetch_vow != 0);
    try std.testing.expect(elapsed_ms < 3_000);
    try std.testing.expectEqual(@as(usize, 1), accepts.opened_count);
    try std.testing.expectEqual(@as(?anyerror, null), accepts.failed_err);
    client_runtime.releaseWire(dials.opened_session.?);
}

test "stepAny self-wakes when a feed_tail still holds incomplete outer-frame bytes" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        opts,
    );
    defer server.close() catch {};
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var accept_future = try io.concurrent(struct {
        fn run(s: *driver.Server) !void {
            var session = try s.accept();
            defer session.deinit();
            try session.serve();
        }
    }.run, .{&server});

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    var client = try driver.connect(
        allocator,
        &netlayers,
        tcp.locator(&designator_buf, address),
        .ephemeral,
        opts,
    );
    defer {
        client.deinit();
        accept_future.await(io) catch {};
    }

    // Drain any connect-time wake so a leftover cannot fake the proof.
    _ = try client.runtime.stepAny(0);

    // An incomplete outer Syrup length prefix (`3:` declares three body
    // bytes that never arrive): parse retains the suffix in `feed_tail`,
    // which no readiness wait can see. Calibrate the pause before asking
    // the nudge to report it.
    try client.runtime.core.feedBytes(client.hs, "3:");
    try std.testing.expect(client.hs.pausedInboundPending());

    const ready_fd = try client.runtime.readinessDescriptor();
    // Resume leaves the incomplete tail, the park times out, and the nudge
    // must leave the aggregate descriptor readable.
    _ = try client.runtime.stepAny(0);
    try std.testing.expect(client.hs.pausedInboundPending());
    var fds = [_]std.posix.pollfd{
        .{ .fd = ready_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const ready = try std.posix.poll(&fds, 0);
    try std.testing.expectEqual(@as(usize, 1), ready);
    try std.testing.expect((fds[0].revents & std.posix.POLL.IN) != 0);
}

test "wakeReadiness raises the descriptor from another thread, and a sessionless step parks instead of refusing" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        opts,
    );
    defer server.close() catch {};

    // No session exists: a step must park on its timeout and report a quiet
    // wait, not refuse with ConnectionClosed.
    try std.testing.expectEqual(@as(?net.Progress, null), try server.runtime.stepAny(0));

    const ready_fd = try server.runtime.readinessDescriptor();
    const waker = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *driver.HostRuntime) void {
            runtime.wakeReadiness();
        }
    }.run, .{server.runtime});
    var fds = [_]std.posix.pollfd{
        .{ .fd = ready_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const ready = try std.posix.poll(&fds, 10_000);
    waker.join();
    try std.testing.expect(ready == 1);
    // The woken step drains the wake and reports quiet; the descriptor is no
    // longer readable afterward, so a parked embedder cannot spin on a
    // consumed wake.
    try std.testing.expectEqual(@as(?net.Progress, null), try server.runtime.stepAny(0));
    fds[0].revents = 0;
    const still_ready = try std.posix.poll(&fds, 0);
    try std.testing.expectEqual(@as(usize, 0), still_ready);
}
