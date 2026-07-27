//! Completion-loop outbound dialing: the same portable loop that accepts many
//! sockets can also initiate many TCP sessions and drive the normal peer seam.

const std = @import("std");
const builtin = @import("builtin");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const tcp = pancake.net.tcp;
const completion = pancake.net.completion;
const Loop = pancake.net.TcpLoop;
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");

const ip = std.Io.net;

const frame_cap = 4096;
const client_count = 4;

fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(tcp.transport_name, designator);
}

fn serverPeer(allocator: std.mem.Allocator) !engine.Peer {
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    errdefer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");
    try peer.sendCopying(startSession("server"));
    return peer;
}

fn serveOne(listener: *tcp.Listener, allocator: std.mem.Allocator) anyerror!void {
    var peer = try serverPeer(allocator);
    defer peer.deinit();

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var conn = try listener.accept(&peer, read_buf, write_buf, .{});
    defer conn.deinit();

    _ = try conn.runUntil(fetch_pump.isOpen, 0);

    var saw_fetch = false;
    var spins: usize = 0;
    while (!saw_fetch and spins < 10_000) : (spins += 1) {
        const progress = conn.pump() catch |err| switch (err) {
            error.ConnectionLost, error.TruncatedFrame => break,
            else => return err,
        };
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            if (event.kind() == .deliver) saw_fetch = true;
        }
        if (progress == .closed) break;
    }
    try std.testing.expect(saw_fetch);
    try conn.flush();
}

fn serveMany(ctx: *ServerCtx) void {
    for (0..ctx.count) |_| {
        serveOne(ctx.listener, ctx.allocator) catch |err| {
            if (ctx.err == null) ctx.err = err;
            return;
        };
    }
}

const ServerCtx = struct {
    listener: *tcp.Listener,
    allocator: std.mem.Allocator,
    count: usize,
    err: ?anyerror = null,
};

const ClientCtx = struct {
    allocator: std.mem.Allocator,
    fulfilled_total: *usize,
    fetch_sent: bool = false,
    answer_position: model.AnswerPosition = .from(0),
    resolver_export: model.ExportPosition = .from(0),
    fulfilled: usize = 0,

    fn serve(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
        const self: *ClientCtx = @ptrCast(@alignCast(conn_ctx.?));
        if (!self.fetch_sent and peer.sessionIsOpen()) {
            const prepared = try engine.fetch.prepareFetchSwissnum(self.allocator, &peer.session_state, "thermostat");
            self.answer_position = prepared.answer_position;
            self.resolver_export = prepared.resolver_export;
            self.fetch_sent = true;
            try peer.send(prepared.message);
            return;
        }
        if (!self.fetch_sent) return;

        const matched = try fetch_pump.matchFetchEvent(
            self.allocator,
            self.resolver_export,
            self.answer_position,
            event,
        );
        if (matched) |reference| {
            model.freeReference(self.allocator, reference);
            self.fulfilled += 1;
            self.fulfilled_total.* += 1;
        }
    }
};

const ClientShared = struct {
    allocator: std.mem.Allocator,
    fulfilled_total: *usize,
};

fn makeClientPeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    _ = ctx;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    errdefer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    try peer.sendCopying(startSession("client"));
    return peer;
}

fn makeClientCtx(ctx: ?*anyopaque, _: *engine.Peer, _: usize) anyerror!?*anyopaque {
    const shared: *ClientShared = @ptrCast(@alignCast(ctx.?));
    const client = try shared.allocator.create(ClientCtx);
    client.* = .{
        .allocator = shared.allocator,
        .fulfilled_total = shared.fulfilled_total,
    };
    return client;
}

fn freeClientCtx(ctx: ?*anyopaque, conn_ctx: ?*anyopaque) void {
    const shared: *ClientShared = @ptrCast(@alignCast(ctx.?));
    const client: *ClientCtx = @ptrCast(@alignCast(conn_ctx.?));
    shared.allocator.destroy(client);
}

fn runLoopCapturing(loop: *Loop, until_closed: usize, out_err: *?anyerror) void {
    loop.run(.{ .after_closed = until_closed }) catch |err| {
        out_err.* = err;
    };
    // `run` returns on the close count alone and leaves any other slot's armed
    // recv in flight, which `deinit` refuses to free. Drain here, on the
    // loop-owner thread, exactly as `closeAndDrain` documents for an early
    // `run` return.
    loop.closeAndDrain() catch |err| {
        out_err.* = err;
    };
}

test "completion loop: outbound dialed sessions fetch from a blocking listener" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, try ip.IpAddress.parse("127.0.0.1", 0));
    defer listener.deinit();
    const address = listener.localAddress();

    var server_ctx = ServerCtx{ .listener = &listener, .allocator = allocator, .count = client_count };
    var server_future = try io.concurrent(serveMany, .{&server_ctx});

    var fulfilled_total: usize = 0;
    var shared = ClientShared{ .allocator = allocator, .fulfilled_total = &fulfilled_total };
    // A pure dialer: no `.listen`, so the loop opens no accepting socket.
    var loop = try Loop.init(allocator, makeClientPeer, @ptrCast(&shared), .{
        .frame_cap = frame_cap,
        .max_conns = 16,
        .make_conn_ctx = makeClientCtx,
        .serve = ClientCtx.serve,
        .free_conn_ctx = freeClientCtx,
    });
    defer loop.deinit();

    for (0..client_count) |_| {
        var buf: [tcp.designator_buf_len]u8 = undefined;
        const loc = tcp.locator(&buf, address);
        _ = try loop.dialLocator(loc.transport, loc.designator, &.{});
    }

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoopCapturing, .{ &loop, @as(usize, client_count), &loop_err });
    loop_future.await(io);
    server_future.await(io);

    if (server_ctx.err) |err| return err;
    if (loop_err) |err| return err;
    try std.testing.expectEqual(@as(usize, client_count), fulfilled_total);
}

/// Journal of `Options.on_close` firings: a refused dial is observable only
/// here (`dial` returns before the connect resolves), so the hook must
/// report each teardown exactly once with `opened == false`.
const CloseJournal = struct {
    closes: usize = 0,
    opened_closes: usize = 0,

    fn onClose(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, opened: bool, reason: completion.CloseReason) void {
        _ = slot;
        _ = reason;
        const self: *CloseJournal = @ptrCast(@alignCast(ctx.?));
        // A connection that never opened never built a per-connection ctx.
        if (!opened) std.debug.assert(conn_ctx == null);
        self.closes += 1;
        if (opened) self.opened_closes += 1;
    }
};

test "completion loop: refused outbound connect closes, reclaims the slot, and fires on_close unopened" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, try ip.IpAddress.parse("127.0.0.1", 0));
    const address = listener.localAddress();
    listener.deinit();

    var journal = CloseJournal{};
    var loop = try Loop.init(allocator, makeClientPeer, @ptrCast(&journal), .{
        .frame_cap = frame_cap,
        .max_conns = 1,
        .on_close = CloseJournal.onClose,
    });
    defer loop.deinit();

    {
        var buf: [tcp.designator_buf_len]u8 = undefined;
        const loc = tcp.locator(&buf, address);
        _ = try loop.dialLocator(loc.transport, loc.designator, &.{});
    }
    try loop.run(.{ .after_closed = 1 });

    // Reusing the single slot proves the failed connect completed teardown.
    {
        var buf: [tcp.designator_buf_len]u8 = undefined;
        const loc = tcp.locator(&buf, address);
        _ = try loop.dialLocator(loc.transport, loc.designator, &.{});
    }
    try loop.run(.{ .after_closed = 2 });

    // Each refused dial fired on_close exactly once, with opened == false:
    // the connect never completed, so the connection never opened.
    try std.testing.expectEqual(@as(usize, 2), journal.closes);
    try std.testing.expectEqual(@as(usize, 0), journal.opened_closes);
}

/// A backend whose connect submission always fails. Dialing through it must
/// surface the error, deinit the slot's peer exactly once (the testing
/// allocator catches a double free), close the socket exactly once, and leave
/// the slot reusable.
const FailingConnectBackend = struct {
    pub const Fd = i32;

    var open_sockets: usize = 0;
    var closed_fds: usize = 0;

    pub fn init(allocator: std.mem.Allocator, queue_entries: u16, read_buffers: u16, read_buffer_bytes: u32) !FailingConnectBackend {
        _ = allocator;
        _ = queue_entries;
        _ = read_buffers;
        _ = read_buffer_bytes;
        return .{};
    }

    pub fn deinit(self: *FailingConnectBackend) void {
        self.* = .{};
    }

    pub fn openListener(self: *@This(), port: u16) !Fd {
        _ = self;
        _ = port;
        return 1;
    }

    pub fn boundPort(fd: Fd) !u16 {
        _ = fd;
        return 1;
    }

    pub fn closeFd(self: *@This(), fd: Fd) void {
        _ = self;
        _ = fd;
        closed_fds += 1;
    }

    pub const ConnectTarget = ip.IpAddress;

    pub fn startDial(self: *@This(), user_data: u64, target: ConnectTarget) !Fd {
        _ = user_data;
        _ = target;
        const fd = try openSocket();
        errdefer self.closeFd(fd);
        return error.SubmitFailed;
    }

    pub fn shutdownFd(self: *@This(), fd: Fd) void {
        _ = self;
        _ = fd;
    }

    pub fn openSocket() !Fd {
        open_sockets += 1;
        return 9;
    }

    pub fn submitAccept(self: *FailingConnectBackend, user_data: u64, listen_fd: Fd) !void {
        _ = self;
        _ = user_data;
        _ = listen_fd;
    }

    pub fn submitRecv(self: *FailingConnectBackend, user_data: u64, fd: Fd) !void {
        _ = self;
        _ = user_data;
        _ = fd;
    }

    pub fn recycleRecv(self: *FailingConnectBackend, comp: completion.Completion) void {
        _ = self;
        _ = comp;
    }

    pub fn submitSend(self: *FailingConnectBackend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        _ = self;
        _ = user_data;
        _ = fd;
        _ = bytes;
    }

    pub fn submitClose(self: *FailingConnectBackend, user_data: u64, fd: Fd) !void {
        _ = self;
        _ = user_data;
        _ = fd;
    }

    pub fn poll(self: *FailingConnectBackend, out: []completion.Completion, timeout_ms: i32) !usize {
        _ = timeout_ms;
        _ = self;
        _ = out;
        return 0;
    }
};

test "completion loop: a failed connect submission frees the peer once and reclaims the slot" {
    const allocator = std.testing.allocator;
    FailingConnectBackend.open_sockets = 0;
    FailingConnectBackend.closed_fds = 0;

    var loop = try completion.Loop(FailingConnectBackend, tcp.DialResolver).init(allocator, makeClientPeer, null, .{
        .frame_cap = frame_cap,
        .max_conns = 1,
    });
    defer loop.deinit();

    const address = try ip.IpAddress.parse("127.0.0.1", 1);
    var buf: [tcp.designator_buf_len]u8 = undefined;
    const loc = tcp.locator(&buf, address);
    try std.testing.expectError(error.SubmitFailed, loop.dialLocator(loc.transport, loc.designator, &.{}));
    // The slot was reclaimed: a second dial reuses it and fails the same way
    // instead of reporting TooManyConnections.
    try std.testing.expectError(error.SubmitFailed, loop.dialLocator(loc.transport, loc.designator, &.{}));
    // Each failed dial opened one socket and closed it exactly once.
    try std.testing.expectEqual(@as(usize, 2), FailingConnectBackend.open_sockets);
    try std.testing.expectEqual(@as(usize, 2), FailingConnectBackend.closed_fds);
}
