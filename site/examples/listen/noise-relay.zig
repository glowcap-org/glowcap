const std = @import("std");
const pancake = @import("pancake");
const native_relay = @import("native_relay");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    // Register this key at the relay; Noise_XK seals every accepted CapTP stream.
    const seed = @as([32]u8, @splat(7)); // load durable secret bytes in a real service
    const secret = pancake.foundation.crypto.SecretKey.fromSeed(seed);
    var relay: native_relay.Provider = undefined;
    switch (relay.init(
        io,
        allocator,
        "wss://relay.example/relay",
        "wss://relay.example/register",
        .system,
    )) {
        .ready => {},
        .failed => return error.RelayUnavailable,
    }
    defer if (relay.deinit()) |chain| std.log.err("relay teardown failed: {s}", .{chain.primaryName()});
    var server = try pancake.driver.listen(
        allocator,
        relay.resident(.noise).netlayer(),
        .{ .designator = "" },
        .{ .keyed = secret },
        .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
    );
    defer server.deinit();

    const uri = try pancake.ocapn.model.uri.writePeer(allocator, (try server.advertisedLocator()));
    defer allocator.free(uri);
    std.debug.print("{s}\n", .{uri}); // Noise seals the relay path end to end

    try serve(&server);
}

// From here, the CapTP workflow is transport-independent.
const Greeter = struct {
    pub fn handle(_: *Greeter, ht: *pancake.driver.HostTurn, verb: []const u8, args: []const pancake.driver.Value) !pancake.driver.Value {
        if (!std.mem.eql(u8, verb, "greet")) return error.NoSuchMethod;
        if (args.len != 1 or args[0] != .string) return error.BadInvocation;
        return .{ .string = try std.fmt.allocPrint(ht.turn.arena, "Hello, {s}", .{args[0].string}) };
    }
};

fn serve(server: *pancake.driver.Server) !void {
    try server.publishGiftable("greeter", Greeter, .{});
    while (true) {
        var session = try server.accept();
        defer session.deinit();
        try session.serve();
    }
}
