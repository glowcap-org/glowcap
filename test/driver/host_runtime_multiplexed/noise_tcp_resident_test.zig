//! `noise-tcp` on HostRuntime through completion residents (ADR-0202): the
//! platform TCP backend carries the bytes on both halves and the byte-fed
//! Host seals them (ADR-0107), so a listener publishes the Host's key with
//! its bound address as a hint, and a dial that completes has proved it.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;

const TcpResident = net.completion_resident.Resident(net.Backend, net.tcp.CompletionPolicy(net.Backend));

const frame_cap = 4096;

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const Echo = struct {
    pub fn handle(_: *Echo, _: *driver.HostTurn, verb: []const u8, _: []const driver.Value) !driver.Value {
        if (!std.mem.eql(u8, verb, "ping")) return error.NoSuchMethod;
        return .{ .string = "pong, sealed" };
    }
};

fn retire(resident: *TcpResident) void {
    resident.closeAndDrain(2_000) catch |err| std.debug.panic("completion resident drain failed: {t}", .{err});
    resident.deinit();
}

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

test "noise-tcp listens and dials on completion residents, sealed by the Host" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const server_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x4e)));
    const server_designator = server_secret.publicKey().toDesignator();
    var server_resident = try TcpResident.init(allocator, try net.Backend.init(allocator, 64, 16, frame_cap), .{});
    defer retire(&server_resident);
    const server_providers = [_]driver.HostRuntime.ProviderRegistration{.{
        .profile = model.transport.Known.noise_tcp.metadata(),
        .resident = server_resident.resident(),
    }};
    var server = try driver.listen(
        allocator,
        io,
        .{ .residents = &server_providers },
        model.transport.noise_tcp,
        .{ .designator = "127.0.0.1:0" },
        .{ .keyed = server_secret },
        opts,
    );
    defer server.deinit();

    // The listener publishes the Host's key, with the bound address beside it.
    const advertised = try model.clonePeerLocator(allocator, try server.advertisedLocator());
    defer model.freePeerLocator(allocator, advertised);
    try std.testing.expectEqualStrings(model.transport.noise_tcp, advertised.transport);
    try std.testing.expectEqualStrings(&server_designator, advertised.designator);
    try std.testing.expect(net.netlayer.directAddrHint(advertised.hints) != null);

    var done = std.atomic.Value(bool).init(false);
    var server_future = try io.concurrent(serve, .{ server, &done });
    defer {
        done.store(true, .release);
        server_future.await(io) catch {};
    }

    var client_resident = try TcpResident.init(allocator, try net.Backend.init(allocator, 64, 16, frame_cap), .{});
    defer retire(&client_resident);
    var client = try driver.HostRuntime.init(allocator, io, .{}, .ephemeral, opts);
    defer client.deinit();
    _ = try client.addResident(model.transport.Known.noise_tcp.metadata(), client_resident.resident());

    const hs = try client.connectLocator(advertised, .inherit);
    const view = try driver.Session.adopt(&client, hs);
    defer view.deinit();

    // The dial's proof comes from the Host's own completed handshake.
    const identity = try client.core.partnerIdentity(hs);
    try std.testing.expectEqual(driver.core.DurableProvenance.authenticated_transport, identity.provenance);
    try std.testing.expect(identity.durableIdentityAuthenticated());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const echo = try view.fetch("echo");
    const settled = try view.call(echo, "ping", &.{}, arena.allocator());
    try std.testing.expect(settled == .fulfilled and settled.fulfilled == .string);
    try std.testing.expectEqualStrings("pong, sealed", settled.fulfilled.string);
}
