const std = @import("std");
const glowcap = @import("glowcap");
const relay_tls = @import("relay_tls");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    // Register this key at the relay; Noise_XK seals every accepted CapTP stream.
    const seed = @as([32]u8, @splat(7)); // load durable secret bytes in a real service
    const secret = glowcap.foundation.crypto.SecretKey.fromSeed(seed);
    var tls = switch (relay_tls.initTlsOwner(io, allocator, .system)) {
        .ready => |ready| ready.owner,
        .failed => return error.RelayUnavailable,
    };
    defer switch (tls.release()) {
        .released => {},
        .busy, .failed => std.log.err("relay TLS teardown failed", .{}),
    };
    var entropy: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randomSecure(&entropy);
    const server = try glowcap.driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.noise_relay}, .relay = .{
            .url = "wss://relay.example/relay",
            .entropy_seed = entropy,
            .resolver_io = io,
            .tls_owner = tls,
            .registration = .{ .url = "wss://relay.example/register" },
        } },
        glowcap.ocapn.model.transport.noise_relay,
        .{ .designator = "" },
        .{ .keyed = secret },
        .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
    );
    defer server.deinit();

    const uri = try glowcap.ocapn.model.uri.writePeer(allocator, (try server.advertisedLocator()));
    defer allocator.free(uri);
    std.debug.print("{s}\n", .{uri}); // Noise seals the relay path end to end

    try serve(server);
}

// From here, the CapTP workflow is transport-independent.
const Greeter = struct {
    pub fn handle(_: *Greeter, ht: *glowcap.driver.HostTurn, verb: []const u8, args: glowcap.driver.Args) !glowcap.driver.Value {
        if (!std.mem.eql(u8, verb, "greet")) return error.NoSuchMethod;
        if ((try args.len()) != 1) return error.BadInvocation;
        return .{ .string = try std.fmt.allocPrint(ht.turn.arena, "Hello, {s}", .{try args.string(0)}) };
    }
};

fn serve(server: *glowcap.driver.Server) !void {
    try server.publish("greeter", Greeter, .{});
    while (true) {
        var session = try server.accept();
        defer session.deinit();
        try session.serve();
    }
}
