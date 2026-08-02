//! Capture, front/sink, listen-refusal, dial retention, timeouts, and signal latch.
const std = @import("std");
const cli = @import("cli");
const pancake = @import("pancake");

const Ctx = cli.ctx.Ctx;
const tcp = pancake.net.tcp;
const model = pancake.ocapn.model;
const ip = std.Io.net;

fn testSecret() pancake.foundation.crypto.SecretKey {
    return pancake.foundation.crypto.SecretKey.fromSeed([_]u8{7} ** 32);
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
    try std.testing.expectEqual(pancake.driver.Budget{ .ms = cli.ocapn.default_handshake_timeout_ms }, opts.handshake);
    try std.testing.expectEqual(pancake.driver.Budget{ .ms = cli.ocapn.default_settle_timeout_ms }, opts.settle);
    // Not merely non-zero: the product front must name a bound, and `unbounded`
    // is now a thing it has to say out loud rather than inherit.
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
    const locator = tcp.locator(&designator_buf, address);
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
    const dir = try std.fmt.bufPrint(&path_buf, "/tmp/pancake-cli-lock-test-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var first = try cli.state_lock.tryAcquire(io, dir);
    defer first.deinit();
    try std.testing.expectError(error.Busy, cli.state_lock.tryAcquire(io, dir));
    try std.testing.expectEqual(cli.exit_codes.busy, cli.state_lock.mapError(error.Busy));
}

test "stateDirOfIdentity strips the identity leaf" {
    try std.testing.expectEqualStrings("/tmp/pancake", cli.state_lock.stateDirOfIdentity("/tmp/pancake/identity"));
    try std.testing.expectEqualStrings(".", cli.state_lock.stateDirOfIdentity("identity"));
}

test "lockPathForIdentity uses state-dir lock or seed-adjacent lock" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/tmp/pancake/lock",
        try cli.state_lock.lockPathForIdentity(&buf, "/tmp/pancake/identity"),
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

    const a_path = "/tmp/pancake-cli-seed-a.lock-test.seed";
    const b_path = "/tmp/pancake-cli-seed-b.lock-test.seed";
    defer std.Io.Dir.cwd().deleteFile(io, a_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, b_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/pancake-cli-seed-a.lock-test.seed.lock") catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "/tmp/pancake-cli-seed-b.lock-test.seed.lock") catch {};

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
    const dir = try std.fmt.bufPrint(&path_buf, "/tmp/pancake-cli-info-{d}", .{std.os.linux.getpid()});
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

test "rooms-peer shim reports missing pancake" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    // Empty PATH and no sibling guarantee → PancakeNotFound (unless a real
    // sibling exists next to the test binary — still ok if found).
    const result = cli.rooms_peer_shim.resolvePancakePath(threaded.io(), gpa, "");
    if (result) |path| {
        defer gpa.free(path);
        try std.testing.expect(path.len > 0);
    } else |err| {
        try std.testing.expect(err == error.PancakeNotFound);
    }
}

test "an unwritable state directory is refused as an identity problem, not a dial failure" {
    // The identity is the first thing `pancake` needs and the first thing the
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
    const dir = try std.fmt.bufPrint(&path_buf, "/tmp/pancake-cli-ro-{d}", .{std.os.linux.getpid()});
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
