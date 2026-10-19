//! Every first-party stream symbol on one completion backend
//! (`net.StreamStack`, ADR-0018): one runtime built from `driver.Transports`
//! reaches a `noise-tcp` listener and an `inproc` listener through the same
//! stack, and the sealed dial proves the listener's key.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;

const supported = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

const frame_cap = 4096;

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const Echo = struct {
    pub fn handle(_: *Echo, _: *driver.HostTurn, verb: []const u8, _: driver.Args) !driver.Value {
        if (!std.mem.eql(u8, verb, "ping")) return error.NoSuchMethod;
        return .{ .string = "pong from the stack" };
    }
};

fn serve(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("echo", Echo, .{});
    while (!done.load(.acquire)) {
        _ = session.stepReadable(20) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => break,
            else => |e| return e,
        };
    }
}

fn listenOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    exchange: *net.inproc_completion.Exchange,
    profile: model.transport.Known,
    designator: []const u8,
    identity: driver.AcceptIdentity,
) !*driver.Server {
    return driver.listen(allocator, io, .{
        .symbols = &.{profile},
        .inproc = exchange,
        .stack = .{ .read_buffer_bytes = frame_cap },
    }, profile.metadata().symbol, .{ .designator = designator }, identity, opts);
}

test "one stream stack dials noise-tcp and inproc through one backend" {
    if (!supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var exchange = net.inproc_completion.Exchange.init(allocator);
    defer exchange.deinit();

    const secret = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x5a)));
    var sealed_server = try listenOne(allocator, io, &exchange, .noise_tcp, "127.0.0.1:0", .{ .keyed = secret });
    defer sealed_server.deinit();
    var inproc_server = try listenOne(allocator, io, &exchange, .inproc, "stack", .ephemeral);
    defer inproc_server.deinit();

    const sealed_locator = try model.clonePeerLocator(allocator, try sealed_server.advertisedLocator());
    defer model.freePeerLocator(allocator, sealed_locator);
    const inproc_locator = try model.clonePeerLocator(allocator, try inproc_server.advertisedLocator());
    defer model.freePeerLocator(allocator, inproc_locator);

    var done = std.atomic.Value(bool).init(false);
    var sealed_future = try io.concurrent(serve, .{ sealed_server, &done });
    var inproc_future = try io.concurrent(serve, .{ inproc_server, &done });
    defer {
        done.store(true, .release);
        sealed_future.await(io) catch {};
        inproc_future.await(io) catch {};
    }

    var client = try driver.HostRuntime.init(allocator, io, .{
        .symbols = &.{ .noise_tcp, .inproc },
        .inproc = &exchange,
        .stack = .{ .read_buffer_bytes = frame_cap },
    }, .ephemeral, opts);
    defer client.deinit();
    // One stack resident serves every symbol the value names.
    try std.testing.expectEqual(@as(usize, 1), client.residents.items.len);

    for ([_]model.PeerLocator{ sealed_locator, inproc_locator }, [_]bool{ true, false }) |locator, sealed| {
        const hs = try client.connectLocator(locator, .inherit);
        const view = try driver.Session.adopt(&client, hs);
        defer view.deinit();
        try std.testing.expectEqual(sealed, (try client.core.partnerIdentity(hs)).durableIdentityAuthenticated());
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const echo = try view.fetch("echo");
        const reply = try view.call(echo, "ping", &.{}, arena.allocator());
        try std.testing.expect(reply == .fulfilled and reply.fulfilled == .string);
        try std.testing.expectEqualStrings("pong from the stack", reply.fulfilled.string);
    }
}

test "a transports value serves only the symbols it names" {
    if (!supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var exchange = net.inproc_completion.Exchange.init(allocator);
    defer exchange.deinit();
    const locator: model.PeerLocator = .{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:1",
        .hints = model.Hints.emptyFalse(),
    };
    try std.testing.expectError(
        driver.Error.UnknownTransport,
        driver.connect(allocator, io, .{ .symbols = &.{.inproc}, .inproc = &exchange }, locator, .ephemeral, opts),
    );
    // A symbol the stack has no adapter for names its own resident instead.
    try std.testing.expectError(
        error.UnknownTransport,
        driver.HostRuntime.init(allocator, io, .{ .symbols = &.{.iroh} }, .ephemeral, opts),
    );
}
