//! The netlayer contract proves that a transport the core never heard of can
//! still drive the driver.
//!
//! `LoopbackResident` is a netlayer defined entirely here, in test code, under
//! the transport symbol `x-loopback`. That symbol appears nowhere in `src/`. The
//! test drives it end to end through the driver's transport-neutral `connectVia`
//! and `acceptVia` with the real verified keyed handshake: bind, accept, dial,
//! fetch a published actor, call it, and read the reply. Nothing in `src/driver`,
//! `src/net`, or the core was edited to add it. The resident registers,
//! and the driver dispatches on its symbol. That demonstrates the pluggability the
//! vision claims: a QUIC/iroh resident slots in the same way.
//!
//! The resident's bytes ride tcp under the hood. This is a loopback test, not a
//! new wire protocol. The driver reaches it only through the contract vtable under
//! an arbitrary symbol, which is the same boundary an external transport author
//! uses.

const std = @import("std");
const pancake = @import("pancake");
const netlayer_test = @import("../support/netlayer.zig");
const support_actors = @import("../support/actors.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const tcp = net.tcp;

const frame_cap = 4096;

/// A netlayer resident defined outside the core, under a fabricated transport
/// symbol. Its dial and listen operations ride tcp's public API; the point is
/// that the driver reaches it only through the contract.
const LoopbackResident = struct {
    io: std.Io,

    const transport = "x-loopback";

    fn netlayer(self: *LoopbackResident) net.netlayer.Netlayer {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: net.netlayer.Netlayer.VTable = .{
        .profile = .{ .symbol = transport, .designator_scheme = .address },
        .dial = .{ .blocking = net.netlayer.adaptBlockingDial(dial) },
        .listen = listen,
    };

    fn dial(
        ctx: *anyopaque,
        peer: *engine.Peer,
        locator: model.PeerLocator,
        bufs: net.netlayer.Buffers,
        _: net.netlayer.OperationOptions,
    ) net.netlayer.DialError!net.Connection {
        const self: *LoopbackResident = @ptrCast(@alignCast(ctx));
        // x-loopback reuses tcp hostport I/O; it is not `tcp`/`keyed-tcp`, so
        // `DialResolver.resolve` would refuse the transport symbol. Parse the
        // designator, then the post-admission connect.
        const address = tcp.parseDesignator(locator.designator) catch return error.InvalidAddress;
        return tcp.connectAddress(self.io, peer, address, bufs.read, bufs.write, .{}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ConnectionLost,
        };
    }

    fn listen(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        config: net.netlayer.ListenConfig,
    ) net.netlayer.ListenStartOutcome {
        return .{ .admitted = listenFallible(ctx, allocator, config) catch |err|
            return .{ .failed = .init(err) } };
    }

    fn listenFallible(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        config: net.netlayer.ListenConfig,
    ) net.netlayer.ListenError!net.netlayer.ListenResult {
        const self: *LoopbackResident = @ptrCast(@alignCast(ctx));
        const address = tcp.parseDesignator(config.designator) catch return error.InvalidAddress;
        const box = allocator.create(ListenerBox) catch return error.OutOfMemory;
        errdefer allocator.destroy(box);
        box.* = .{
            .listener = tcp.Listener.bind(self.io, address) catch return error.BindFailed,
            .allocator = allocator,
        };
        return .{ .ready = .{ .ctx = box, .vtable = &listener_vtable } };
    }

    const ListenerBox = struct {
        listener: tcp.Listener,
        allocator: std.mem.Allocator,
    };

    const listener_vtable: net.netlayer.Listener.VTable = .{
        .transport_name = transport,
        .accept = net.netlayer.adaptAccept(accept),
        .wait_acceptable = net.netlayer.adaptAcceptReadiness(waitAcceptable),
        .local_locator = net.netlayer.adaptListenerLocator(localLocator),
        .canonicalize_locator = net.netlayer.adaptListenerCanonicalize(canonicalizeLocator),
        .close = close,
    };

    fn accept(ctx: *anyopaque, peer: *engine.Peer, bufs: net.netlayer.Buffers) net.netlayer.AcceptError!net.Connection {
        const box: *ListenerBox = @ptrCast(@alignCast(ctx));
        return box.listener.accept(peer, bufs.read, bufs.write, .{}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ConnectionLost,
        };
    }

    fn waitAcceptable(ctx: *anyopaque, timeout_ms: i32) net.netlayer.AcceptError!bool {
        const box: *ListenerBox = @ptrCast(@alignCast(ctx));
        return tcp.waitAcceptableOnListener(&box.listener, timeout_ms);
    }

    fn localLocator(ctx: *anyopaque, allocator: std.mem.Allocator) net.netlayer.ListenError!model.PeerLocator {
        const box: *ListenerBox = @ptrCast(@alignCast(ctx));
        var designator_buf: [tcp.plain.designator_buf_len]u8 = undefined;
        const tcp_locator = tcp.locatorFromAddress(&designator_buf, box.listener.localAddress());
        return model.clonePeerLocator(allocator, .{
            .transport = transport,
            .designator = tcp_locator.designator,
            .hints = tcp_locator.hints,
        });
    }

    fn canonicalizeLocator(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) net.netlayer.ListenError!model.PeerLocator {
        model.validatePeerLocator(locator) catch return error.InvalidAddress;
        if (!std.mem.eql(u8, locator.transport, transport)) return error.InvalidAddress;
        _ = tcp.parseDesignator(locator.designator) catch return error.InvalidAddress;
        return model.clonePeerLocator(allocator, locator);
    }

    fn close(ctx: *anyopaque) ?net.netlayer.ListenerCloseFailure {
        const box: *ListenerBox = @ptrCast(@alignCast(ctx));
        box.listener.deinit();
        box.allocator.destroy(box);
        return null;
    }
};

/// The published actor: answers `greet` with a static greeting.
const Greeter = support_actors.StaticReplyActor("greet", "hello over x-loopback");

/// Host: accept one partner through `acceptVia`, publish the greeter, serve.
fn hostOnce(listener: net.netlayer.Listener, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = try driver.acceptVia(allocator, listener, &peer, .ephemeral, read_buf, write_buf, .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } });
    defer cv.deinit();

    _ = try cv.publish("greeter", Greeter, .{});
    try cv.serve();
}

/// Client: dial through `connectVia` on the `x-loopback` symbol, fetch, call.
fn callOnce(netlayers: []const net.netlayer.Netlayer, designator: []const u8, allocator: std.mem.Allocator) !void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const locator: model.PeerLocator = .{
        .transport = "x-loopback",
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    };
    var cv = try driver.connectVia(allocator, netlayers, &peer, locator, .ephemeral, read_buf, write_buf, .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } });
    defer cv.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const greeter = try cv.fetch("greeter");
    const settled = try cv.call(greeter, .{ .verb = "greet", .args = &.{.{ .string = "world" }} }, arena_state.allocator());
    switch (settled) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .string);
            try std.testing.expectEqualStrings("hello over x-loopback", arg.string);
        },
        .broken, .give => return error.CallBroke,
    }
}

test "netlayer pluggability: an out-of-core transport dials and hosts through the driver" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Register the test-defined transport. The driver dispatches on its symbol.
    var resident = LoopbackResident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{resident.netlayer()};

    var listener = try netlayer_test.listenBlocking(net.netlayer.resolve(&netlayers, "x-loopback").?, allocator, .{
        .designator = "127.0.0.1:0",
    });
    defer netlayer_test.close(listener);

    const locator = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, locator);

    var host_future = try io.concurrent(hostOnce, .{ listener, allocator });
    const client_result = callOnce(&netlayers, locator.designator, allocator);
    const host_result = host_future.await(io);

    try client_result;
    try host_result;
}
