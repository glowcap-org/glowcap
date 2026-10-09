//! The settle-path fault mapping (R3) and the silent-partner budgets: a
//! clean transport loss becomes `ConnectionClosed` with far vows broken as
//! "connection lost", any other fault propagates raw as "connection failed",
//! and every keyed wait against a partner that goes quiet times out instead
//! of parking a fiber.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;
const net = glowcap.net;
const syrup = glowcap.ocapn.codec.syrup;
const crypto = glowcap.foundation.crypto;

const ip = std.Io.net;

const harness = @import("harness.zig");
const handshake_budget = harness.handshake_budget;
const frame_cap = harness.frame_cap;
const dial_opts = harness.dial_opts;
const connectPlain = harness.connectPlain;
const acceptPlain = harness.acceptPlain;
const Greeter = harness.Greeter;
const HostedGreeter = harness.HostedGreeter;

// ── faultToClosed: the settle-path fault mapping (R3) ────────────────────────
//
// The chokepoint `settle`'s flush-catch and step-catch both route through has
// two arms — a clean transport loss becomes `ConnectionClosed` with the far
// vows broken as "connection lost", any other fault propagates raw with the
// vows broken as "connection failed". `serve`'s own catch is a separate path
// (it returns void and does not break on the non-transport arm), so it does not
// exercise these arms; only a blocking call driven to a transport fault does.
// Both arms are pinned deterministically here by feeding a `BlockingSession`
// over a fixed reader that yields the exact framing failure — no timing.

const zero_pubkey_fault = @as([32]u8, @splat(0));
const zero_sig_fault = @as([64]u8, @splat(0));

/// A whole stub-key `op:start-session` frame, encoded so the caller can take a
/// prefix of it to drive a mid-frame EOF (`TruncatedFrame`).
fn faultStartSessionFrame(allocator: std.mem.Allocator) !glowcap.foundation.Frame {
    return syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
        .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &zero_pubkey_fault },
            .acceptable_location = .{ .transport = "memory", .designator = "remote", .hints = model.Hints.emptyMap() },
            .acceptable_location_sig = .{ .bytes = &zero_sig_fault },
        },
    });
}

fn faultNoopClose(ctx: *anyopaque) void {
    _ = ctx;
}
fn faultNoopSocket(ctx: *anyopaque) ?std.Io.net.Socket.Handle {
    _ = ctx;
    return null;
}

/// Captures the break reason the far vows carry when `faultToClosed` runs.
const FaultBreakCapture = struct {
    broke: bool = false,
    reason: [64]u8 = undefined,
    reason_len: usize = 0,
    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *FaultBreakCapture = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .broken => |reason| {
                self.broke = true;
                const n = @min(reason.len, self.reason.len);
                @memcpy(self.reason[0..n], reason[0..n]);
                self.reason_len = n;
            },
            else => {},
        }
    }
    fn reasonHas(self: *const FaultBreakCapture, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.reason[0..self.reason_len], needle) != null;
    }
};

/// Build a `BlockingSession` over an established peer and a fixed reader/writer:
/// the reader's bytes are the exact framing the settle-path step will read.
const FaultHarness = struct {
    pair: engine.pairing.Pair,
    reader: std.Io.Reader,
    write_buf: [512]u8 = undefined,
    writer: std.Io.Writer = undefined,
    cv: driver.BlockingSession = undefined,

    fn init(allocator: std.mem.Allocator, io: std.Io, inbound: []const u8) !*FaultHarness {
        const self = try allocator.create(FaultHarness);
        self.pair = try engine.pairing.pairedV1_0Syrup(allocator);
        // A far import the questioner can address; the send mints a far vow.
        try self.pair.p1.importObject(7);
        self.reader = std.Io.Reader.fixed(inbound);
        self.writer = std.Io.Writer.fixed(&self.write_buf);
        const Transport = @FieldType(net.Connection, "transport");
        const handle = Transport{ .ctx = self, .close_fn = faultNoopClose, .socket_handle_fn = faultNoopSocket };
        const conn = net.Connection.init(io, &self.pair.p1, &self.reader, &self.writer, handle);
        self.cv = driver.BlockingSession.over(allocator, &self.pair.p1, conn, .{ .handshake = .unbounded, .settle = .unbounded });
        return self;
    }

    fn deinit(self: *FaultHarness, allocator: std.mem.Allocator) void {
        self.cv.deinit();
        self.pair.deinit();
        allocator.destroy(self);
    }
};

test "faultToClosed: a transport truncation during a blocking call breaks far vows with 'connection lost' and reports ConnectionClosed" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The inbound the settle-path step reads: the first half of a whole frame,
    // then EOF — a mid-frame truncation, surfaced as `error.TruncatedFrame`.
    var whole = try faultStartSessionFrame(allocator);
    defer whole.deinit();
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(allocator);
    _ = try net.appendFrameBytes(&framed, allocator, whole.bytes());
    const half = framed.items[0 .. framed.items.len / 2];

    var h = try FaultHarness.init(allocator, io, half);
    defer h.deinit(allocator);

    // A vow allows one listener, and `settleVow` registers its own, so observe
    // the break on a second far vow: `breakFarVows` breaks every far vow.
    const observe = try h.cv.send(.{ .far = model.FarRef.object(7) }, .{ .verb = "x", .args = &.{} });
    var capture = FaultBreakCapture{};
    try h.cv.on(observe, .{ .ctx = &capture, .func = FaultBreakCapture.fire });
    const settle_vow = try h.cv.send(.{ .far = model.FarRef.object(7) }, .{ .verb = "x", .args = &.{} });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ConnectionClosed, h.cv.settleVow(settle_vow, arena.allocator()));
    try std.testing.expect(capture.broke);
    try std.testing.expect(capture.reasonHas("connection lost"));
}

test "faultToClosed: a non-transport fault during a blocking call breaks far vows with 'connection failed' and propagates the raw error" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Structurally invalid bytes: a length-mismatched symbol, surfaced as
    // `error.MalformedFrame` — the non-transport `else` arm.
    var h = try FaultHarness.init(allocator, io, "<7'op:foo>");
    defer h.deinit(allocator);

    const observe = try h.cv.send(.{ .far = model.FarRef.object(7) }, .{ .verb = "x", .args = &.{} });
    var capture = FaultBreakCapture{};
    try h.cv.on(observe, .{ .ctx = &capture, .func = FaultBreakCapture.fire });
    const settle_vow = try h.cv.send(.{ .far = model.FarRef.object(7) }, .{ .verb = "x", .args = &.{} });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MalformedFrame, h.cv.settleVow(settle_vow, arena.allocator()));
    try std.testing.expect(capture.broke);
    try std.testing.expect(capture.reasonHas("connection failed"));
}

/// Manual dial rather than `connectVia`: dial the socket, bind the vat over it,
/// arm the deadline, then drive the keyed handshake here, so the timeout has an
/// entry point this test can name and assert on. `connectVia` takes the same
/// budget and would break the same way, but it breaks inside the constructor,
/// which leaves nothing to inspect afterwards. A partner that completes connect
/// and then never speaks must break the handshake, not park the fiber
/// (ADR-0081, contract 2).
fn silentPartnerHandshakeTimesOut(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator, budget: driver.Budget) !void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, 64);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var resident = tcp.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{resident.netlayer()};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const locator = tcp.locatorFromAddress(&designator_buf, address);
    const nl = net.netlayer.resolve(&netlayers, locator.transport).?;
    const conn = try nl.dial(&peer, locator, .{ .read = read_buf, .write = write_buf }, .inherit);

    var vat = driver.BlockingSession.over(allocator, &peer, conn, .{ .handshake = budget, .settle = .unbounded });
    defer vat.deinit();

    const ident: driver.Identity = .ephemeral;
    const self_locator: model.PeerLocator = .{
        .transport = locator.transport,
        .designator = ident.dialedDesignator(),
        .hints = model.Hints.emptyFalse(),
    };
    try std.testing.expectError(driver.Error.HandshakeTimedOut, vat.startKeyedSession(self_locator));
}

test "driver loopback: a silent partner's keyed handshake breaks with HandshakeTimedOut, not a parked fiber" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Bind but never accept: the kernel completes connect into the backlog while
    // the peer stays silent through the whole handshake window.
    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();

    try silentPartnerHandshakeTimesOut(io, address, allocator, .{ .ms = 200 });
}

test "an expired handshake budget times out at once instead of reading zero as forever" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();

    // `.ms = 0` is a budget that has already expired, in every build mode. The
    // OS poll vocabulary underneath reads zero as forever, so if this guard
    // regresses the test does not fail — it parks, which is why the suite runs
    // under a timeout wrapper.
    try silentPartnerHandshakeTimesOut(io, address, allocator, .{ .ms = 0 });
    try silentPartnerHandshakeTimesOut(io, address, allocator, .{ .ms = -1 });
}

test "owning connect: a silent partner's handshake breaks with HandshakeTimedOut through the pump" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Bind but never accept: the kernel completes connect into the backlog
    // while the peer stays silent through the whole handshake window. This is
    // the owning tier's twin of the manual-dial test above — the budget here
    // is `Host.pumpHandshake`'s deadline arithmetic, not the borrowing tier's.
    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectError(driver.Error.HandshakeTimedOut, driver.connect(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        tcp.locatorFromAddress(&buf, listener.localAddress()),
        .ephemeral,
        .{ .frame_cap = frame_cap, .handshake = .{ .ms = 200 }, .settle = .{ .ms = 200 } },
    ));

    // An already-expired budget times out before the first poll, every build mode.
    try std.testing.expectError(driver.Error.HandshakeTimedOut, driver.connect(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        tcp.locatorFromAddress(&buf, listener.localAddress()),
        .ephemeral,
        .{ .frame_cap = frame_cap, .handshake = .{ .ms = 0 }, .settle = .{ .ms = 200 } },
    ));
}

/// A raw TCP client that completes connect and then says nothing for longer
/// than the accepter's handshake budget: the ADR-0081 slowloris, aimed at the
/// owning accept path so its failure unwind runs under the testing allocator
/// (the accept-side handshake failure once double-freed the wire buffers).
fn silentRawDialer(io: std.Io, address: ip.IpAddress) anyerror!void {
    var addr = address;
    const stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(800), .real) catch {};
}

test "owning accept: a connect-then-silent dialer times out and the unwind stays memory-clean" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, .{
        .frame_cap = frame_cap,
        .handshake = .{ .ms = 200 },
        .settle = .{ .ms = 200 },
    });
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var dialer = try io.concurrent(silentRawDialer, .{ io, address });
    defer dialer.await(io) catch {};

    try std.testing.expectError(driver.Error.HandshakeTimedOut, server.accept());
}

/// Host half that completes the keyed handshake and publishes, then never
/// serves — the partner opens then stalls, the settle budget's target.
fn hostAcceptPublishThenStall(server: *driver.Server, io: std.Io) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("root", HostedGreeter, .{});
    // Hold the connection open without pumping CapTP until the client's
    // settle budget fires and it drops the socket; then exit.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2000), .real) catch {};
}

fn silentPartnerSettleTimesOut(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    var session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&buf, address), .ephemeral, .{
        .frame_cap = frame_cap,
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 200 },
    });
    defer session.deinit();
    try std.testing.expectError(driver.Error.WaitTimedOut, session.fetch("root"));
}

test "driver loopback: a partner that opens then stalls breaks settle with WaitTimedOut, not a parked fiber" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, dial_opts);
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    const host_thread = try std.Thread.spawn(.{}, hostAcceptPublishThenStall, .{ server, io });
    defer host_thread.join();

    try silentPartnerSettleTimesOut(io, address, allocator);
}
