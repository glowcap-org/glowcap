//! The onion resident driven against a fake Tor daemon.
//!
//! Nothing here needs Tor, a network, or an onion address that resolves. A fake
//! SOCKS proxy on loopback answers the handshake and then becomes the far peer,
//! and a fake control endpoint answers `AUTHENTICATE` and `ADD_ONION`. That is
//! enough to prove the two things the byte-level tests cannot: that a real CapTP
//! session runs over a dial once the handshake is done, and that a listener
//! reports the service id Tor named rather than one glowcap chose.
//!
//! What this cannot prove is that a real Tor accepts these bytes. The byte
//! expectations live in `onion_socks5_test.zig` and `onion_control_test.zig`,
//! pinned against the two reference implementations; `zig build onion-interop`
//! and `zig build goblins-onion` are the opt-in live Tor proofs.

const std = @import("std");
const glowcap = @import("glowcap");
const netlayer_test = @import("../support/netlayer.zig");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const onion = glowcap.net.onion;
const socks5 = onion.socks5;
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");

/// The stub-negotiating peer the other loopback transport proofs use: handshake
/// signature verification is off, because this test exercises the transport and
/// its framing rather than keyed identity.
fn stubPeer(allocator: std.mem.Allocator) engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
}

const ip = std.Io.net;
const frame_cap = 4096;

test "onion.locator builds the Goblins-compatible borrowed locator" {
    const locator = onion.locator(service_id);
    try std.testing.expectEqualStrings(onion.transport_name, locator.transport);
    try std.testing.expectEqualStrings(service_id, locator.designator);
    try std.testing.expectEqual(@as(usize, 0), locator.hints.entries.len);
    try std.testing.expectEqual(model.Hints.WireForm.boolean_false, locator.hints.wire_form);
}

/// A transport handle over a stream somebody else closes. The fake daemons in
/// this file own their streams directly, so the connection must not close them.
fn borrowedHandle(reader: *std.Io.net.Stream.Reader) glowcap.net.Connection.Transport {
    return .{
        .ctx = reader,
        .close_fn = struct {
            fn noop(_: *anyopaque) void {}
        }.noop,
        .socket_handle_fn = struct {
            fn handle(ctx: *anyopaque) ?std.Io.net.Socket.Handle {
                const r: *std.Io.net.Stream.Reader = @ptrCast(@alignCast(ctx));
                return r.stream.socket.handle;
            }
        }.handle,
    };
}

/// A real, checksum-valid version 3 id, from the pinned Goblins source.
const service_id = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";

/// A second valid id, so a test can tell "the id Tor said" from "the id glowcap
/// was configured with". Derived by regenerating the checksum for a different
/// key, so it is well-formed rather than merely different.
const other_service_id = "p53lf57qovyuvwsc6xnrppyply3vtqm7l6pcs2sgui4gvx3nspnr3sad";

// --- The fake SOCKS proxy ------------------------------------------------

const FakeSocksResult = struct {
    /// Every byte the client wrote before the handshake completed, so the test
    /// can assert the request rather than trust the client's own formatter.
    request: [socks5.connect_request_len]u8,
    greeting: [socks5.greeting.len]u8,
};

/// Answer one SOCKS5 handshake, then serve the bootstrap fetch as the far peer.
///
/// Serving CapTP afterwards is the point. A proxy that only completed the
/// handshake would leave the interesting question open: whether the resident
/// handed the session a stream positioned exactly after the reply, with no reply
/// byte left to be parsed as a frame and no session byte thrown away.
fn fakeSocksServe(
    io: std.Io,
    listener: *glowcap.net.tcp.plain.Listener,
    allocator: std.mem.Allocator,
    out: *FakeSocksResult,
) anyerror!void {
    const stream = try listener.acceptStream();
    defer stream.close(io);

    var read_buf: [frame_cap]u8 = undefined;
    var write_buf: [frame_cap]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    const r = &reader.interface;
    const w = &writer.interface;

    try r.readSliceAll(&out.greeting);
    try w.writeAll(&[_]u8{ 0x05, 0x00 });
    try w.flush();

    try r.readSliceAll(&out.request);
    // Version 5, success, reserved, then a legal domain-form bound address and
    // port. Tor normally answers null IPv4, but SOCKS5 permits all three address
    // forms; using the uncommon one here proves the live handshake consumes its
    // length byte and payload before handing the stream to CapTP.
    //
    // Deliberately not flushed. The session's first write carries it, so the
    // reply and this peer's hello reach the client in one segment. That is the
    // hazard the resident's shared reader exists for: a handshake reading through
    // its own throwaway buffer would take the hello off the socket with the reply
    // and drop it when that buffer went out of scope, and the client would then
    // wait forever for a hello already sent. Flushing separately hides it, since
    // two segments let a throwaway reader stop after the first.
    try w.writeAll(&[_]u8{ 0x05, 0x00, 0x00, 0x03, 3, 't', 'o', 'r', 0, 0 });

    // From here the stream is the far peer: a full CapTP session over the very
    // reader and writer the handshake used.
    var peer = stubPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");

    // The fake peer borrows the stream its own `defer` closes, so the handle is
    // inert: a `deinit` that closed here would double-close.
    var conn = glowcap.net.Connection.init(io, &peer, r, w, borrowedHandle(&reader));
    defer conn.deinit();

    try peer.sendCopying(handshake.startSession(onion.transport_name, service_id));
    while (true) {
        const progress = conn.pump() catch |err| switch (err) {
            error.ConnectionLost, error.TruncatedFrame => break,
            else => return err,
        };
        if (progress == .closed) break;
    }
}

test "a dial hands the session a stream positioned after the SOCKS reply" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The fake proxy stands in for Tor's SOCKS endpoint on loopback.
    var proxy = try glowcap.net.tcp.plain.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer proxy.deinit();
    var socks_text: [64]u8 = undefined;
    const socks = try std.fmt.bufPrint(&socks_text, "{f}", .{proxy.localAddress()});

    var observed: FakeSocksResult = undefined;
    var server = try io.concurrent(fakeSocksServe, .{ io, &proxy, allocator, &observed });

    const client = dialAndFetch(io, allocator, socks);
    const server_result = server.await(io);
    try client;
    try server_result;

    // The proxy saw exactly the bytes the conformance tests pin.
    try std.testing.expectEqualSlices(u8, &socks5.greeting, &observed.greeting);
    var expected: [socks5.connect_request_len]u8 = undefined;
    const want = try socks5.writeConnectRequest(&expected, service_id);
    try std.testing.expectEqualSlices(u8, want, &observed.request);
}

fn dialAndFetch(io: std.Io, allocator: std.mem.Allocator, socks: []const u8) anyerror!void {
    var peer = stubPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    var read_buf: [frame_cap]u8 = undefined;
    var write_buf: [frame_cap]u8 = undefined;

    var res: onion.Resident = .{ .io = io, .config = .{ .socks = socks } };
    const layer = res.netlayer();
    try std.testing.expectEqualStrings("onion", layer.transportName());

    var conn = try layer.dial(&peer, .{
        .transport = onion.transport_name,
        .designator = service_id,
        .hints = model.Hints.emptyFalse(),
    }, .{ .read = &read_buf, .write = &write_buf }, .inherit);
    defer conn.deinit();

    try fetch_pump.handshakeToOpen(&peer, &conn, handshake.startSession(onion.transport_name, service_id));
    const reference = try fetch_pump.settleFetch(allocator, &peer, &conn, "thermostat");
    model.freeReference(allocator, reference);
}

test "a dial refuses a designator that is not a version 3 address before connecting" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var peer = stubPeer(allocator);
    defer peer.deinit();
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    // The SOCKS endpoint is a port nothing listens on. A refusal that reached the
    // socket would report ConnectionRefused, so InvalidAddress is what proves the
    // check ran first.
    var res: onion.Resident = .{ .io = io, .config = .{ .socks = "127.0.0.1:1" } };
    const layer = res.netlayer();
    try std.testing.expectError(error.InvalidAddress, layer.dial(&peer, .{
        .transport = onion.transport_name,
        .designator = "not-a-v3-onion-address",
        .hints = model.Hints.emptyFalse(),
    }, .{ .read = &read_buf, .write = &write_buf }, .inherit));
}

// --- The fake control endpoint -------------------------------------------

const FakeControlResult = struct {
    /// Each request line the daemon received, terminator stripped.
    lines: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    fn deinit(self: *FakeControlResult) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
    }
};

/// Answer `AUTHENTICATE` and one `ADD_ONION`, recording what was asked.
fn fakeControlServe(
    io: std.Io,
    listener: *glowcap.net.tcp.plain.Listener,
    out: *FakeControlResult,
) anyerror!void {
    const stream = try listener.acceptStream();
    defer stream.close(io);

    var read_buf: [1024]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    const r = &reader.interface;
    const w = &writer.interface;

    // AUTHENTICATE
    try out.lines.append(out.allocator, try takeLine(out.allocator, r));
    try w.writeAll("250 OK\r\n");
    try w.flush();

    // ADD_ONION, answered the way Tor answers: the id, the key, then the
    // terminator, exactly the three lines the pinned Goblins reads.
    try out.lines.append(out.allocator, try takeLine(out.allocator, r));
    try w.writeAll("250-ServiceID=" ++ service_id ++ "\r\n");
    try w.writeAll("250-PrivateKey=ED25519-V3:c3RvcmVkLWtleQ==\r\n");
    try w.writeAll("250 OK\r\n");
    try w.flush();

    // The undetached service lives for exactly this control connection. Listener
    // release closes it and performs no control write.
    try std.testing.expectError(error.EndOfStream, r.takeByte());
}

fn takeLine(allocator: std.mem.Allocator, r: *std.Io.Reader) anyerror![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    while (true) {
        const b = try r.takeByte();
        if (b == '\n') break;
        if (b == '\r') continue;
        try buf.append(allocator, b);
    }
    return buf.toOwnedSlice(allocator);
}

fn fakeControlRejectAuth(io: std.Io, listener: *glowcap.net.tcp.plain.Listener) anyerror!void {
    const stream = try listener.acceptStream();
    defer stream.close(io);

    var read_buf: [128]u8 = undefined;
    var write_buf: [128]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    const line = try takeLine(std.testing.allocator, &reader.interface);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("AUTHENTICATE", line);
    try writer.interface.writeAll("515 Authentication failed\r\n");
    try writer.interface.flush();

    // `ControlSession.open` owns the stream as soon as connect succeeds. An
    // authentication refusal must close it on the failing path; there is no
    // initialized session for the caller to close afterwards.
    try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
}

test "a refused control authentication closes the unreturned stream" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctrl_listener = try glowcap.net.tcp.plain.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer ctrl_listener.deinit();
    var ctrl_text: [64]u8 = undefined;
    const endpoint_text = try std.fmt.bufPrint(&ctrl_text, "{f}", .{ctrl_listener.localAddress()});
    var server = try io.concurrent(fakeControlRejectAuth, .{ io, &ctrl_listener });

    var ctrl: onion.session.ControlSession = undefined;
    try std.testing.expectError(
        error.AuthFailed,
        ctrl.open(io, try onion.Endpoint.parse(endpoint_text), .none),
    );
    try server.await(io);
}

test "a listener publishes the service id Tor named, not one glowcap chose" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctrl_listener = try glowcap.net.tcp.plain.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer ctrl_listener.deinit();
    var ctrl_text: [64]u8 = undefined;
    const ctrl = try std.fmt.bufPrint(&ctrl_text, "{f}", .{ctrl_listener.localAddress()});

    var observed: FakeControlResult = .{ .lines = .empty, .allocator = allocator };
    defer observed.deinit();
    var server = try io.concurrent(fakeControlServe, .{ io, &ctrl_listener, &observed });

    const client = listenAndInspect(io, allocator, ctrl);
    const server_result = server.await(io);
    try client;
    try server_result;

    // The daemon was asked for a fresh v3 service forwarding 9045.
    try std.testing.expect(observed.lines.items.len >= 2);
    try std.testing.expectEqualStrings("AUTHENTICATE", observed.lines.items[0]);
    const add = observed.lines.items[1];
    try std.testing.expect(std.mem.startsWith(u8, add, "ADD_ONION NEW:ED25519-V3 PORT=9045,"));
    // With no configured forward the listener binds a loopback port and names the
    // one the OS chose, so the target is an address rather than a socket path.
    try std.testing.expect(std.mem.indexOf(u8, add, ",127.0.0.1:") != null);
}

test "onion listener returns Unix-socket removal failure" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctrl_listener = try glowcap.net.tcp.plain.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer ctrl_listener.deinit();
    var ctrl_text: [64]u8 = undefined;
    const ctrl = try std.fmt.bufPrint(&ctrl_text, "{f}", .{ctrl_listener.localAddress()});
    var observed: FakeControlResult = .{ .lines = .empty, .allocator = allocator };
    defer observed.deinit();
    var control_server = try io.concurrent(fakeControlServe, .{ io, &ctrl_listener, &observed });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", allocator);
    defer allocator.free(tmp_path);
    var socket_path_buf: [108]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_path_buf, "{s}/forward.sock", .{tmp_path});
    const listener = switch (onion.Listener.create(allocator, io, .{
        .socks = "127.0.0.1:1",
        .control_endpoint = ctrl,
        .forward = socket_path,
    })) {
        .ready => |listener| listener,
        .failed => |failure| return failure.cause,
    };

    // Remove the actual socket inode, then make teardown target the containing
    // directory. Deleting a directory through deleteFileAbsolute must fail,
    // deterministically exercising the returned cleanup-only outcome without
    // leaking the real forward socket.
    try std.Io.Dir.deleteFileAbsolute(io, listener.unix_path.?);
    listener.unix_path = tmp_path;
    const failure = listener.deinit() orelse return error.ExpectedCleanupFailure;
    try std.testing.expect(failure.cause != error.FileNotFound);
    try std.testing.expectEqual(@as(u16, 0), failure.secondary_count);
    try control_server.await(io);
}

fn blockedOnionAccept(listener: *onion.Listener, out_err: *?anyerror) void {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var stream = listener.acceptFrameStream(
        std.testing.allocator,
        .syrup,
        frame_cap,
        &read_buf,
        &write_buf,
    ) catch |err| {
        out_err.* = err;
        return;
    };
    stream.deinit();
    out_err.* = error.UnexpectedAccept;
}

fn blockedOnionWait(listener: *onion.Listener, out_err: *?anyerror) void {
    _ = listener.waitAcceptable(-1) catch |err| {
        out_err.* = err;
        return;
    };
    out_err.* = error.UnexpectedReadiness;
}

test "onion listener shutdown wakes and joins a blocked accept before release" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctrl_listener = try glowcap.net.tcp.plain.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer ctrl_listener.deinit();
    var ctrl_text: [64]u8 = undefined;
    const ctrl = try std.fmt.bufPrint(&ctrl_text, "{f}", .{ctrl_listener.localAddress()});

    var observed: FakeControlResult = .{ .lines = .empty, .allocator = allocator };
    defer observed.deinit();
    var control_server = try io.concurrent(fakeControlServe, .{ io, &ctrl_listener, &observed });

    const listener = switch (onion.Listener.create(allocator, io, .{
        .socks = "127.0.0.1:1",
        .control_endpoint = ctrl,
    })) {
        .ready => |listener| listener,
        .failed => |failure| return failure.cause,
    };
    var accept_err: ?anyerror = null;
    var accept_future = try io.concurrent(blockedOnionAccept, .{ listener, &accept_err });

    listener.shutdown();
    accept_future.await(io);
    try std.testing.expectEqual(error.ConnectionLost, accept_err.?);

    try std.testing.expect(listener.deinit() == null);
    try control_server.await(io);
}

test "onion listener shutdown joins a blocked readiness wait before release" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctrl_listener = try glowcap.net.tcp.plain.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer ctrl_listener.deinit();
    var ctrl_text: [64]u8 = undefined;
    const ctrl = try std.fmt.bufPrint(&ctrl_text, "{f}", .{ctrl_listener.localAddress()});

    var observed: FakeControlResult = .{ .lines = .empty, .allocator = allocator };
    defer observed.deinit();
    var control_server = try io.concurrent(fakeControlServe, .{ io, &ctrl_listener, &observed });

    const listener = switch (onion.Listener.create(allocator, io, .{
        .socks = "127.0.0.1:1",
        .control_endpoint = ctrl,
    })) {
        .ready => |listener| listener,
        .failed => |failure| return failure.cause,
    };
    var wait_err: ?anyerror = null;
    var wait_future = try io.concurrent(blockedOnionWait, .{ listener, &wait_err });

    listener.shutdown();
    wait_future.await(io);
    try std.testing.expectEqual(error.ConnectionLost, wait_err.?);

    try std.testing.expect(listener.deinit() == null);
    try control_server.await(io);
}

fn listenAndInspect(io: std.Io, allocator: std.mem.Allocator, ctrl: []const u8) anyerror!void {
    var res: onion.Resident = .{ .io = io, .config = .{
        .socks = "127.0.0.1:1",
        .control_endpoint = ctrl,
    } };
    const layer = res.netlayer();
    var listener = try netlayer_test.listenBlocking(layer, allocator, .{ .designator = "ignored" });
    defer netlayer_test.close(listener);

    const locator = try listener.localLocator(allocator);
    defer glowcap.ocapn.model.freePeerLocator(allocator, locator);
    // The designator is the id the reply carried, and it is not the other
    // well-formed id, so this cannot pass by accident.
    try std.testing.expectEqualStrings(service_id, locator.designator);
    try std.testing.expect(!std.mem.eql(u8, other_service_id, locator.designator));
    try std.testing.expectEqualStrings("onion", locator.transport);
    // An address designator says where to dial, so there is no dial hint. A
    // hinted onion locator is undialable by the pinned Goblins (ADR-0108).
    try std.testing.expectEqual(@as(usize, 0), locator.hints.entries.len);
    try std.testing.expectEqual(
        glowcap.ocapn.model.transport.DesignatorScheme.address,
        listener.designatorScheme(),
    );
}

test "hosting without a control endpoint is refused rather than silently skipped" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A dial-only resident. Reporting success here would leave a caller believing
    // it was reachable at an address that does not exist.
    var res: onion.Resident = .{ .io = io, .config = .{ .socks = "127.0.0.1:1" } };
    const layer = res.netlayer();
    try std.testing.expectError(
        error.InvalidAddress,
        netlayer_test.listenBlocking(layer, allocator, .{ .designator = "" }),
    );
}

// --- The endpoint forms --------------------------------------------------

test "an endpoint is a socket path or an address, and nothing else" {
    const Endpoint = onion.Endpoint;

    const unix = try Endpoint.parse("/run/tor/control");
    try std.testing.expect(unix.isUnix());
    try std.testing.expectEqualStrings("/run/tor/control", unix.unix);

    const addr = try Endpoint.parse("127.0.0.1:9051");
    try std.testing.expect(!addr.isUnix());

    const v6 = try Endpoint.parse("[::1]:9051");
    try std.testing.expect(!v6.isUnix());

    // A relative path is refused rather than read as a hostname whose port is
    // missing, which is how `tor-control-sock` would otherwise fail.
    try std.testing.expectError(error.InvalidEndpoint, Endpoint.parse("tor-control-sock"));
    try std.testing.expectError(error.InvalidEndpoint, Endpoint.parse(""));
    try std.testing.expectError(error.InvalidEndpoint, Endpoint.parse("127.0.0.1"));
    try std.testing.expectError(error.InvalidEndpoint, Endpoint.parse("127.0.0.1:notaport"));
    try std.testing.expectError(error.InvalidEndpoint, Endpoint.parse("127.0.0.1:99999"));
}
