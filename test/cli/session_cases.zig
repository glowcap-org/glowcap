//! Capture, front/sink, listen-refusal, dial retention, timeouts, and signal latch.
const std = @import("std");
const cli = @import("cli");
const glowcap = @import("glowcap");

const Ctx = cli.ctx.Ctx;
const tcp = glowcap.net.tcp;
const model = glowcap.ocapn.model;
const ip = std.Io.net;

fn testSecret() glowcap.foundation.crypto.SecretKey {
    return glowcap.foundation.crypto.SecretKey.fromSeed(@as([32]u8, @splat(7)));
}

fn makeCtx(io: std.Io, gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) Ctx {
    return .{
        .io = io,
        .gpa = gpa,
        .environ = environ,
        .front = .argv,
        .json = .json,
        .secret = testSecret(),
    };
}

test "writeResult appends to sink buffer" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = makeCtx(threaded.io(), gpa, &environ);
    defer c.deinit();

    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(gpa);
    c.sink = .{ .buffer = &capture };
    try c.writeResult("hello-captp\n");
    try std.testing.expectEqualStrings("hello-captp\n", capture.items);
}

test "an unavailable CapTP transport is named before identity creation" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var ctx: Ctx = .{ .io = threaded.io(), .gpa = gpa, .environ = &environ };
    defer ctx.deinit();
    cli.log.test_capture.reset();
    try std.testing.expectError(error.UnknownTransport, cli.ocapn.dialUriWithOpts(
        &ctx,
        "ocapn://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.iroh",
        cli.ocapn.sessionOpts(),
    ));
    try std.testing.expect(ctx.secret == null);
    try std.testing.expect(ctx.state_guard == null);
    try std.testing.expect(std.mem.indexOf(u8, cli.log.test_capture.captured(), "transport 'iroh' is not registered") != null);
}

test "listen backgrounds on the MCP front: bind now, one listener, close stops it" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = makeCtx(threaded.io(), gpa, &environ);
    defer c.deinit();
    c.front = .mcp;
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(gpa);
    c.sink = .{ .buffer = &capture };

    var parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer parsed.deinit();
    try parsed.setString("bind", "127.0.0.1:0");
    // The verb returns at once with the locator; the accept loop is the
    // background thread's.
    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdListen(&c, &parsed));
    try std.testing.expect(c.background_listener != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "\"listening\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "ocapn://") != null);

    // One listener per context: a second listen refuses loud.
    var second = cli.cmd_types.Parsed{ .gpa = gpa };
    defer second.deinit();
    try second.setString("bind", "127.0.0.1:0");
    try std.testing.expectEqual(cli.exit_codes.usage, try cli.ocapn.cmdListen(&c, &second));

    // `close` stops the accept thread and clears the handle.
    var close_parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer close_parsed.deinit();
    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdClose(&c, &close_parsed));
    try std.testing.expect(c.background_listener == null);
}

test "dial retains session for REPL and MCP fronts only" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = makeCtx(threaded.io(), gpa, &environ);
    defer c.deinit();

    try std.testing.expect(!cli.ocapn.retainSessionAfterDial(&c));

    c.front = .repl;
    try std.testing.expect(cli.ocapn.retainSessionAfterDial(&c));

    c.front = .mcp;
    try std.testing.expect(cli.ocapn.retainSessionAfterDial(&c));

    c.front = .argv;
    try std.testing.expect(!cli.ocapn.retainSessionAfterDial(&c));
}

test "refused one-shot remains the reachable pending owner" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = makeCtx(threaded.io(), gpa, &environ);

    var primary: glowcap.driver.Session = undefined;
    var sidecar: glowcap.driver.Session = undefined;
    c.holdSession(&primary);
    c.retainPendingSession(&sidecar);

    try std.testing.expectEqual(&sidecar, c.pending_session.?);
    try std.testing.expectEqual(&primary, c.session.?);
    try std.testing.expectError(error.CleanupPending, c.ensureDialAllowed());
    try std.testing.expectEqual(cli.exit_codes.busy, cli.ocapn.mapDialErr(error.CleanupPending));
    try std.testing.expectError(
        error.CleanupPending,
        cli.ocapn.dialUriWithOpts(&c, "ocapn://blocked", cli.ocapn.sessionOpts()),
    );
}

test "pending sidecar admission resumes only after cleanup settles" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = makeCtx(threaded.io(), gpa, &environ);

    var primary: glowcap.driver.Session = undefined;
    var first: glowcap.driver.Session = undefined;
    var second: glowcap.driver.Session = undefined;
    c.holdSession(&primary);
    c.retainPendingSession(&first);
    try std.testing.expectError(error.CleanupPending, c.ensureDialAllowed());

    // The close barrier's successful transition is the only operation that
    // clears the fixed owner; a new sidecar is admitted only afterwards.
    c.pending_session = null;
    try c.ensureDialAllowed();
    c.retainPendingSession(&second);
    try std.testing.expectEqual(&second, c.pending_session.?);
}

test "a refused held-session close is not exposed as an active session" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = makeCtx(threaded.io(), gpa, &environ);

    var held: glowcap.driver.Session = undefined;
    c.holdSession(&held);
    c.session_cleanup_pending = true;

    try std.testing.expect(c.activeSession() == null);
    try std.testing.expect(c.sessionCleanupPending());
    try std.testing.expectError(error.CleanupPending, c.ensureDialAllowed());
}

test "signals stop latch is set by requestStop" {
    cli.signals.resetForTest();
    try std.testing.expect(!cli.signals.stopRequested());
    cli.signals.requestStop();
    try std.testing.expect(cli.signals.stopRequested());
    cli.signals.resetForTest();
    try std.testing.expect(!cli.signals.stopRequested());
}

test "CLI session opts refuse unbounded CapTP waits" {
    const opts = cli.ocapn.sessionOpts();
    try std.testing.expectEqual(glowcap.driver.Budget{ .ms = cli.ocapn.default_handshake_timeout_ms }, opts.handshake);
    try std.testing.expectEqual(glowcap.driver.Budget{ .ms = cli.ocapn.default_settle_timeout_ms }, opts.settle);
    // Not merely non-zero: the product front must name a bound. `.unbounded`
    // is an explicit choice, not a silent default.
    try std.testing.expect(opts.handshake == .ms and opts.handshake.ms > 0);
    try std.testing.expect(opts.settle == .ms and opts.settle.ms > 0);
}

test "dial against silent partner times out (no hang)" {
    // Bind but never accept: connect completes into the backlog, handshake stalls.
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const locator = tcp.locatorFromAddress(&designator_buf, address);
    const uri = try model.uri.writePeer(gpa, .{
        .transport = locator.transport,
        .designator = locator.designator,
        .hints = model.Hints.emptyFalse(),
    });
    defer gpa.free(uri);

    var c = makeCtx(io, gpa, &environ);
    defer c.deinit();

    // 200ms budget: an unbounded dial would hang until the outer build timeout.
    const dial_err = cli.ocapn.dialUriWithOpts(&c, uri, .{ .handshake = .{ .ms = 200 }, .settle = .{ .ms = 200 } });
    try std.testing.expectError(error.HandshakeTimedOut, dial_err);
    try std.testing.expectEqual(cli.exit_codes.timeout, cli.ocapn.mapDialErr(error.HandshakeTimedOut));
    try std.testing.expectEqual(cli.exit_codes.timeout, cli.ocapn.mapDialErr(error.WaitTimedOut));
}

test "state-dir lock is exclusive" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, "/tmp/glowcap-cli-lock-test-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var first = try cli.state_lock.tryAcquire(io, dir);
    defer first.deinit();
    try std.testing.expectError(error.Busy, cli.state_lock.tryAcquire(io, dir));
    try std.testing.expectEqual(cli.exit_codes.busy, cli.state_lock.mapError(error.Busy));
}

test "stateDirOfIdentity strips the identity leaf" {
    try std.testing.expectEqualStrings("/tmp/glowcap", cli.state_lock.stateDirOfIdentity("/tmp/glowcap/identity"));
    try std.testing.expectEqualStrings(".", cli.state_lock.stateDirOfIdentity("identity"));
}

test "lockPathForIdentity uses state-dir lock or seed-adjacent lock" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/tmp/glowcap/lock",
        try cli.state_lock.lockPathForIdentity(&buf, "/tmp/glowcap/identity"),
    );
    try std.testing.expectEqualStrings(
        "/tmp/peer.seed.lock",
        try cli.state_lock.lockPathForIdentity(&buf, "/tmp/peer.seed"),
    );
}

test "loose identity seeds do not share a /tmp state lock" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const a_path = "/tmp/glowcap-cli-seed-a.lock-test.seed";
    const b_path = "/tmp/glowcap-cli-seed-b.lock-test.seed";
    defer std.Io.Dir.cwd().deleteFile(io, a_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, b_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/glowcap-cli-seed-a.lock-test.seed.lock") catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/glowcap-cli-seed-b.lock-test.seed.lock") catch {};

    var first = try cli.state_lock.tryAcquireForIdentity(io, a_path);
    defer first.deinit();
    var second = try cli.state_lock.tryAcquireForIdentity(io, b_path);
    defer second.deinit();
    try std.testing.expectError(error.Busy, cli.state_lock.tryAcquireForIdentity(io, a_path));
}

test "info succeeds under state-dir lock with preset identity path" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, "/tmp/glowcap-cli-info-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var id_buf: [std.fs.max_path_bytes]u8 = undefined;
    const id_path = try std.fmt.bufPrint(&id_buf, "{s}/identity", .{dir});

    var c = makeCtx(io, gpa, &environ);
    defer c.deinit();
    @memcpy(c.identity_path_buf[0..id_path.len], id_path);
    c.identity_path = c.identity_path_buf[0..id_path.len];
    c.secret = null; // force ensureSecret → lock + mint
    c.json = .json;

    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(gpa);
    c.sink = .{ .buffer = &capture };

    var parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer parsed.deinit();
    const code = try cli.ocapn.cmdInfo(&c, &parsed);
    try std.testing.expectEqual(cli.exit_codes.ok, code);
    try std.testing.expect(c.state_guard != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "\"front\":\"argv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "\"path\":") != null);
}

test "mcp lifecycle defaults are finite" {
    try std.testing.expect(cli.mcp.default_idle_ms > 0);
    try std.testing.expect(cli.mcp.default_max_session_ms > 0);
    try std.testing.expect(cli.mcp.default_max_session_ms > cli.mcp.default_idle_ms);
}

test "an unwritable state directory is refused as an identity problem, not a dial failure" {
    // The identity is the first thing `glowcap` needs and the first thing the
    // quickstart tells a reader to create, so a state directory nobody can
    // write has to say so. It used to exit with a bare code and no output, and
    // `ocapn info` reported it through the dial mapper, which sends the reader
    // looking at the network for a permissions problem.
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, "/tmp/glowcap-cli-ro-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer {
        _ = std.os.linux.chmod(@ptrCast(dir.ptr), 0o700);
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try std.Io.Dir.cwd().createDirPath(io, dir);

    // A path one level below a directory that refuses new entries, so both the
    // lock and the mint fail the way an unwritable home does.
    var id_buf: [std.fs.max_path_bytes]u8 = undefined;
    const id_path = try std.fmt.bufPrint(&id_buf, "{s}/sub/identity", .{dir});
    var dir_z: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(dir_z[0..dir.len], dir);
    dir_z[dir.len] = 0;
    if (std.os.linux.chmod(@ptrCast(&dir_z), 0o500) != 0) return error.SkipZigTest;

    var c = makeCtx(io, gpa, &environ);
    defer c.deinit();
    @memcpy(c.identity_path_buf[0..id_path.len], id_path);
    c.identity_path = c.identity_path_buf[0..id_path.len];
    c.secret = null;

    var parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer parsed.deinit();
    const code = try cli.ocapn.cmdInfo(&c, &parsed);
    try std.testing.expect(code != cli.exit_codes.ok);
    // Anything but the dial code: this is not a network failure and reporting
    // it as one is what sent the reader in the wrong direction.
    try std.testing.expect(code != cli.exit_codes.dial);
}

test "listen --rendezvous reaches the background front, not just argv" {
    // A flag accepted and silently ignored is worse than one refused. The
    // background listener reads the same flag through the same owner
    // (`ocapn.listenTarget`), so the locator it prints names the relay
    // transport rather than a TCP address nobody asked for.
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = makeCtx(threaded.io(), gpa, &environ);
    defer c.deinit();
    c.front = .mcp;
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(gpa);
    c.sink = .{ .buffer = &capture };

    // A relay URL that parses but has nobody behind it: registration fails,
    // which is a dial failure and not a silent fallback to TCP.
    var parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer parsed.deinit();
    try parsed.setString("rendezvous", "ws://127.0.0.1:1/register");
    try parsed.setString("rendezvous-relay", "ws://127.0.0.1:1/relay");
    const code = try cli.ocapn.cmdListen(&c, &parsed);
    try std.testing.expectEqual(cli.exit_codes.dial, code);
    try std.testing.expect(c.background_listener == null);

    // Registration and dialing are separate relay endpoints. Refuse to emit
    // a locator with no route instead of pretending the registration URL is
    // dialable.
    var missing_route = cli.cmd_types.Parsed{ .gpa = gpa };
    defer missing_route.deinit();
    try missing_route.setString("rendezvous", "ws://127.0.0.1:1/register");
    try std.testing.expectEqual(cli.exit_codes.usage, try cli.ocapn.cmdListen(&c, &missing_route));
    try std.testing.expect(c.background_listener == null);

    // A malformed URL is caller error, refused by the shared owner.
    var bad = cli.cmd_types.Parsed{ .gpa = gpa };
    defer bad.deinit();
    try bad.setString("rendezvous", "http://not-a-relay/");
    try bad.setString("rendezvous-relay", "ws://127.0.0.1:1/relay");
    try std.testing.expectEqual(cli.exit_codes.usage, try cli.ocapn.cmdListen(&c, &bad));
    try std.testing.expect(c.background_listener == null);
}

test "info reports a background listener that died on its own" {
    // The handle outlives its accept thread, so the handle's presence is not
    // evidence the listener is alive. A loop that stopped by itself records
    // why, and `info` must report that rather than keep claiming to listen.
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = makeCtx(threaded.io(), gpa, &environ);
    defer c.deinit();
    c.front = .mcp;
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(gpa);
    c.sink = .{ .buffer = &capture };

    var parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer parsed.deinit();
    try parsed.setString("bind", "127.0.0.1:0");
    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdListen(&c, &parsed));

    // A live listener says so.
    capture.clearRetainingCapacity();
    var info_parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer info_parsed.deinit();
    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdInfo(&c, &info_parsed));
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "\"listening\":true") != null);

    // Simulate the loop stopping by itself, the way a relay drop would.
    c.background_listener.?.stop_reason.store("ConnectionLost", .release);
    capture.clearRetainingCapacity();
    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdInfo(&c, &info_parsed));
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "\"listening\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "ConnectionLost") != null);

    // The benign stop reports the same way: a one-partner listener that
    // served its partner is not listening, and says why, rather than
    // reporting a live accept loop it no longer runs.
    const lb = @import("cli").ocapn_listen_background;
    c.background_listener.?.stop_reason.store(lb.Handle.served_stop, .release);
    capture.clearRetainingCapacity();
    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdInfo(&c, &info_parsed));
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "\"listening\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "served its one partner") != null);

    // Human output carries the same lifecycle truth as JSON output.
    c.json = .human;
    capture.clearRetainingCapacity();
    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdInfo(&c, &info_parsed));
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "listening: false") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "listener_stopped: served its one partner") != null);
}

test "close composition keeps the primary and notes cleanup as a consequence" {
    const FailureChain = glowcap.foundation.FailureChain;
    var failure: ?FailureChain = FailureChain.init(error.ConnectionLost);
    var unused: cli.ctx.Ctx = undefined;
    unused.retainCleanup(&failure, FailureChain.init(error.CloseTimedOut));
    try std.testing.expectEqual(error.ConnectionLost, failure.?.cause);
    try std.testing.expectEqual(error.CloseTimedOut, failure.?.secondary_cause.?);
    try std.testing.expectEqual(@as(u16, 1), failure.?.secondary_count);

    var empty: ?FailureChain = null;
    unused.retainCleanup(&empty, FailureChain.init(error.Busy));
    try std.testing.expectEqual(error.Busy, empty.?.cause);
    try std.testing.expectEqual(@as(u16, 0), empty.?.secondary_count);
}

test "close keeps accept-thread listener failure as the command outcome" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = makeCtx(threaded.io(), gpa, &environ);
    defer c.deinit();
    c.front = .mcp;
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(gpa);
    c.sink = .{ .buffer = &capture };

    var parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer parsed.deinit();
    try parsed.setString("bind", "127.0.0.1:0");
    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdListen(&c, &parsed));

    const listener = c.background_listener.?;
    cli.ocapn_listen_background.Handle.testing.requestTerminalFailure(listener);
    capture.clearRetainingCapacity();
    var close_parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer close_parsed.deinit();
    try std.testing.expectEqual(cli.exit_codes.dial, try cli.ocapn.cmdClose(&c, &close_parsed));
    try std.testing.expect(c.background_listener == null);
    try std.testing.expect(std.mem.indexOf(u8, capture.items, "SocketConfigurationFailed") != null);

    // Consuming: a second close has no listener left to retry.
    capture.clearRetainingCapacity();
    var again = cli.cmd_types.Parsed{ .gpa = gpa };
    defer again.deinit();
    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdClose(&c, &again));
}
