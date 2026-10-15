const std = @import("std");
const glowcap = @import("glowcap");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    const seed = @as([32]u8, @splat(7)); // load durable secret bytes in a real service
    const secret = glowcap.foundation.crypto.SecretKey.fromSeed(seed);
    const server = try glowcap.driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.noise_tcp} },
        glowcap.ocapn.model.transport.noise_tcp,
        .{ .designator = "127.0.0.1:9099" },
        .{ .keyed = secret },
        .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
    );
    defer server.deinit();

    const uri = try glowcap.ocapn.model.uri.writePeer(allocator, (try server.advertisedLocator()));
    defer allocator.free(uri);
    std.debug.print("{s}\n", .{uri}); // Noise proves this durable key to dialers

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
