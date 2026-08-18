const std = @import("std");
const pancake = @import("pancake");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    const seed = [_]u8{7} ** 32; // load durable secret bytes in a real service
    const secret = pancake.foundation.crypto.SecretKey.fromSeed(seed);
    var relay_resident = try pancake.net.relay.Resident.initRegisteredProfile(
        allocator,
        io,
        "ws://192.0.2.10:8080/relay",
        "ws://192.0.2.10:8080/register",
        secret.publicKey(),
        .noise,
    );
    defer relay_resident.deinit();
    var server = try pancake.driver.listen(
        allocator,
        relay_resident.netlayer(),
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
