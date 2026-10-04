//! Staged dials and the close lifecycle (ADR-0112): the staged-open
//! admission bound, a staged dial serving a fetch and keeping its claimed
//! session through retirement, the step-clock handshake timeout, and every
//! cancel/finish close arm — interruption, publication before close,
//! deadline escalation, and one session's timeout leaving its Host active.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;

const frame_cap = 8192;

const harness = @import("harness.zig");
const FailureCapture = harness.FailureCapture;
const Treasure = harness.Treasure;
const stepServe = harness.stepServe;
const CloseFlag = harness.CloseFlag;
const DropSessionOnClose = harness.DropSessionOnClose;
const connectAndHold = harness.connectAndHold;
const RecordingSink = harness.RecordingSink;
const DialRecorder = harness.DialRecorder;
const opts = harness.opts;

test "a blocking netlayer returns its exact failure chain to the dial observer" {
    const ExactFailureResident = struct {
        fn netlayer() net.netlayer.Netlayer {
            return .{ .ctx = undefined, .vtable = &vtable };
        }

        const vtable: net.netlayer.Netlayer.VTable = .{
            .profile = .{ .symbol = "exact-blocking", .designator_scheme = .address },
            .dial = .{ .blocking = dial },
            .listen = null,
        };

        fn dial(
            _: *anyopaque,
            _: *glowcap.ocapn.engine.Peer,
            _: model.PeerLocator,
            _: net.netlayer.Buffers,
            _: net.OperationOptions,
        ) net.netlayer.DialOutcome {
            var chain = glowcap.foundation.FailureChain.initNamed(
                error.ProviderIo,
                "ExactBlockingDialRefusal",
            );
            chain.noteNamed(error.ProviderIo, "ExactBlockingDialCleanup");
            return .{ .failed = .fromChain(error.ConnectionRefused, chain) };
        }
    };

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const layers = [_]net.netlayer.Netlayer{ExactFailureResident.netlayer()};
    var runtime = try driver.HostRuntime.init(allocator, threaded.io(), &layers, .ephemeral, opts);
    defer runtime.deinit();
    var recorder = DialRecorder{};

    try runtime.startDial(.{
        .transport = "exact-blocking",
        .designator = "target",
        .hints = model.Hints.emptyFalse(),
    }, .inherit, 41, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    const failure = recorder.failure orelse return error.MissingDialFailure;
    try std.testing.expectEqual(@as(u64, 41), recorder.failed_tag);
    try std.testing.expectEqual(driver.OperationFailure.Kind.io, failure.kind);
    try std.testing.expectEqualStrings("ExactBlockingDialRefusal", failure.primaryName());
    try std.testing.expectEqualStrings("ExactBlockingDialCleanup", failure.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 1), failure.secondary_count);
}

test "a staged dial serves a fetch and retirement preserves its claimed session" {
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
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var sink = RecordingSink{};
    var client_runtime = try driver.HostRuntime.init(
        allocator,
        io,
        &netlayers,
        .ephemeral,
        harness.stepped(sink.sink(), harness.Quiet.observer()),
    );
    defer client_runtime.deinit();
    sink.core = client_runtime.core;
    var recorder = DialRecorder{};

    // Stage the dial and return unopened: the blocking `connectLocator`
    // would park here inside its handshake pump, which no single-thread
    // topology can ever satisfy.
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    try client_runtime.startDial(tcp.locatorFromAddress(&designator_buf, address), .inherit, 7, .{
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
    try session.attend();

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
    const vow_id = try client_runtime.core.fetch(hs, "treasure");
    var waited: usize = 0;
    while (sink.settled.load(.acquire) == 0 and waited < 1_000) : (waited += 1) {
        _ = try client_runtime.stepAny(10);
        while (try server.runtime.stepAny(0) != null) {}
    }
    try std.testing.expectEqual(vow_id, sink.settled.load(.acquire));

    try client_runtime.claimSessionHandle(hs);
    client_runtime.beginRetirement();
    try std.testing.expectEqual(driver.core.Host.LifecyclePhase.active, client_runtime.lifecyclePhase());
    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.pending, client_runtime.closeOutcome());
    try std.testing.expectError(
        driver.Error.HostClosing,
        client_runtime.startDial(tcp.locatorFromAddress(&designator_buf, address), .inherit, 8, .{
            .ctx = &recorder,
            .opened = DialRecorder.opened,
            .failed = DialRecorder.failed,
        }),
    );

    try client_runtime.releaseWire(hs);
    while (client_runtime.closeOutcome() == .pending) _ = try client_runtime.stepAny(0);
    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.closed, client_runtime.closeOutcome());
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
    defer server.deinit();
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
    try client_runtime.startDial(tcp.locatorFromAddress(&designator_buf, address), .inherit, 9, .{
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

test "runtime cancel close interrupts an admitted transport open and seals admission" {
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
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var runtime = try driver.HostRuntime.init(allocator, io, &netlayers, .ephemeral, opts);
    defer runtime.deinit();
    var recorder = DialRecorder{};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const locator = tcp.locatorFromAddress(&designator_buf, address);
    try runtime.startDial(locator, .inherit, 31, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });
    try std.testing.expectEqual(@as(usize, 1), runtime.pending_opens.items.len);

    runtime.beginClose(.cancel);
    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.pending, runtime.closeOutcome());
    _ = try runtime.stepAny(0);
    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.closed, runtime.closeOutcome());
    try std.testing.expectEqual(@as(usize, 0), runtime.pending_opens.items.len);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), recorder.failed_err);
    try std.testing.expectError(error.HostClosing, runtime.startDial(locator, .inherit, 32, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    }));
}

test "runtime finish close publishes an admitted transport open before closing its session" {
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
    defer server.deinit();
    var address_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var runtime = try driver.HostRuntime.init(allocator, io, &netlayers, .ephemeral, opts);
    defer runtime.deinit();
    var recorder = DialRecorder{};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    try runtime.startDial(tcp.locatorFromAddress(&designator_buf, address), .inherit, 37, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    runtime.beginClose(.{ .finish = .{ .ms = 1_000 } });
    _ = try runtime.stepAny(0);
    var accepted = try server.accept();
    defer accepted.deinit();
    try accepted.attend();

    var rounds: usize = 0;
    while (runtime.closeOutcome() == .pending and rounds < 1_000) : (rounds += 1) {
        _ = try runtime.stepAny(10);
        while (try server.runtime.stepAny(0) != null) {}
    }

    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.closed, runtime.closeOutcome());
    try std.testing.expectEqual(@as(usize, 1), recorder.opened_count);
    try std.testing.expectEqual(@as(?anyerror, null), recorder.failed_err);
    const opened = recorder.opened_session orelse return error.DialNeverOpened;
    try runtime.releaseWire(opened);
}

test "runtime finish close realizes a core dial admitted before its barrier" {
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
    defer server.deinit();
    var address_buf: [64]u8 = undefined;
    const designator = try server.localDesignator(&address_buf);

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var runtime = try driver.HostRuntime.init(allocator, io, &netlayers, .ephemeral, opts);
    defer runtime.deinit();
    try runtime.core.ensureAdvertisedLocator("tcp");
    _ = try runtime.core.enlivenSelectOrDial(.{
        .peer = .{
            .transport = "tcp",
            .designator = designator,
            .hints = model.Hints.emptyFalse(),
        },
        .swissnum = "not-published",
    });

    runtime.beginClose(.{ .finish = .{ .ms = 1_000 } });
    _ = try runtime.stepAny(0);

    try std.testing.expect(try server.waitAcceptable(100));
    var accepted = try server.accept();
    defer accepted.deinit();
    try accepted.attend();

    var rounds: usize = 0;
    while (runtime.closeOutcome() == .pending and rounds < 1_000) : (rounds += 1) {
        _ = try runtime.stepAny(10);
        while (try server.runtime.stepAny(0) != null) {}
    }

    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.closed, runtime.closeOutcome());
}

test "runtime close preserves an exposed session until explicit release" {
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
    defer server.deinit();
    var address_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var runtime = try driver.HostRuntime.init(allocator, io, &netlayers, .ephemeral, opts);
    defer runtime.deinit();
    var recorder = DialRecorder{};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    try runtime.startDial(tcp.locatorFromAddress(&designator_buf, address), .inherit, 34, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    _ = try runtime.stepAny(0);
    var accepted = try server.accept();
    defer accepted.deinit();
    try accepted.attend();
    var rounds: usize = 0;
    while (recorder.opened_session == null and recorder.failed_err == null and rounds < 1_000) : (rounds += 1) {
        _ = try runtime.stepAny(10);
        while (try server.runtime.stepAny(0) != null) {}
    }
    const session = recorder.opened_session orelse return error.DialNeverOpened;

    try runtime.close(.cancel);
    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.closed, runtime.closeOutcome());
    try runtime.core.checkOwnedSession(session);
    try runtime.releaseWire(session);
}

test "blocking session cancel returns after immediate transport teardown" {
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
    defer server.deinit();
    var address_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var runtime = try driver.HostRuntime.init(allocator, io, &netlayers, .ephemeral, opts);
    defer runtime.deinit();
    var recorder = DialRecorder{};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    try runtime.startDial(tcp.locatorFromAddress(&designator_buf, address), .inherit, 36, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    _ = try runtime.stepAny(0);
    var accepted = try server.accept();
    defer accepted.deinit();
    try accepted.attend();
    var rounds: usize = 0;
    while (recorder.opened_session == null and recorder.failed_err == null and rounds < 1_000) : (rounds += 1) {
        _ = try runtime.stepAny(10);
        while (try server.runtime.stepAny(0) != null) {}
    }
    const session = recorder.opened_session orelse return error.DialNeverOpened;

    try runtime.closeSession(session, .cancel);

    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.closed, runtime.sessionCloseOutcome(session));
    try std.testing.expectEqual(driver.core.Host.LifecyclePhase.active, runtime.lifecyclePhase());
    try runtime.releaseWire(session);
}

test "runtime finish close escalates on its own deadline and reports timeout after teardown" {
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
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var runtime = try driver.HostRuntime.init(allocator, io, &netlayers, .ephemeral, opts);
    defer runtime.deinit();
    var recorder = DialRecorder{};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    try runtime.startDial(tcp.locatorFromAddress(&designator_buf, address), .inherit, 33, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    const started_ms = net.clock.nowMs(io);
    runtime.beginClose(.{ .finish = .{ .ms = 50 } });
    while (runtime.closeOutcome() == .pending) _ = try runtime.stepAny(-1);
    const elapsed_ms = net.clock.nowMs(io) - started_ms;

    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.timed_out, runtime.closeOutcome());
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), recorder.failed_err);
    try std.testing.expect(elapsed_ms < 3_000);

    // A repeated finish observes the original timed-out barrier; it cannot
    // create a second grace period or weaken the cancel escalation.
    runtime.beginClose(.{ .finish = .unbounded });
    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.timed_out, runtime.closeOutcome());
}

test "session finish timeout terminates only that session and leaves its Host active" {
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
    defer server.deinit();
    var address_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var runtime = try driver.HostRuntime.init(allocator, io, &netlayers, .ephemeral, opts);
    defer runtime.deinit();
    var recorder = DialRecorder{};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    try runtime.startDial(tcp.locatorFromAddress(&designator_buf, address), .inherit, 35, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    _ = try runtime.stepAny(0);
    var accepted = try server.accept();
    defer accepted.deinit();
    try accepted.attend();
    var rounds: usize = 0;
    while (recorder.opened_session == null and recorder.failed_err == null and rounds < 1_000) : (rounds += 1) {
        _ = try runtime.stepAny(10);
        while (try server.runtime.stepAny(0) != null) {}
    }
    const session = recorder.opened_session orelse return error.DialNeverOpened;

    // The fetch is admitted, but the server stops stepping before it can
    // answer. Session finish must therefore reach its finite deadline.
    _ = try runtime.core.fetch(session, "never-answered");
    const started_ms = net.clock.nowMs(io);
    try runtime.beginSessionClose(session, .{ .finish = .{ .ms = 25 } });
    while (runtime.sessionCloseOutcome(session) == .pending) _ = try runtime.stepAny(-1);
    const elapsed_ms = net.clock.nowMs(io) - started_ms;

    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.timed_out, runtime.sessionCloseOutcome(session));
    try std.testing.expect(session.isTerminating());
    try std.testing.expectEqual(driver.core.Host.LifecyclePhase.active, runtime.lifecyclePhase());
    try std.testing.expectEqual(driver.HostRuntime.CloseOutcome.pending, runtime.closeOutcome());
    try std.testing.expect(elapsed_ms < 3_000);
    try runtime.releaseWire(session);
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
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
    var closed = std.atomic.Value(bool).init(false);
    var close_flag = CloseFlag{ .flag = &closed };
    var client_runtime = try driver.HostRuntime.init(
        allocator,
        io,
        &netlayers,
        .ephemeral,
        harness.stepped(harness.Quiet.sink(), .{ .ctx = &close_flag, .closed = CloseFlag.notify }),
    );
    defer client_runtime.deinit();
    var recorder = DialRecorder{};

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    try client_runtime.startDial(tcp.locatorFromAddress(&designator_buf, address), .inherit, 11, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });
    _ = try client_runtime.stepAny(0);

    // Tearing the listener down resets its never-accepted backlog
    // connection; the pump sees the loss on the next step. The dial path
    // owns the report — a close event would name a session the embedder
    // never received.
    try std.testing.expect(server.close() == null);
    var rounds: usize = 0;
    while (recorder.failed_err == null and rounds < 1_000) : (rounds += 1) {
        _ = try client_runtime.stepAny(10);
    }
    try std.testing.expectEqual(@as(u64, 11), recorder.failed_tag);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionLost), recorder.failed_err);
    try std.testing.expect(!closed.load(.acquire));
}
