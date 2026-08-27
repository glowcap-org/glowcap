const std = @import("std");
const pancake = @import("pancake");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    const seed = @as([32]u8, @splat(7)); // load durable secret bytes in a real service
    const secret = pancake.foundation.crypto.SecretKey.fromSeed(seed);
    var noise_resident = pancake.net.tcp.noise.Resident{ .io = io };
    const server = try pancake.driver.listen(
        allocator,
        noise_resident.netlayer(),
        .{ .designator = "127.0.0.1:9099" },
        .{ .keyed = secret },
        .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
    );
    defer server.deinit();

    const uri = try pancake.ocapn.model.uri.writePeer(allocator, (try server.advertisedLocator()));
    defer allocator.free(uri);
    std.debug.print("{s}\n", .{uri}); // Noise proves this durable key to dialers

    try serve(server);
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
