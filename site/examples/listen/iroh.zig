const std = @import("std");
const glowcap = @import("glowcap");
const iroh = @import("iroh");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    var seed: [32]u8 = undefined;
    try io.randomSecure(&seed); // retain this seed to restore the node identity
    const secret = glowcap.foundation.crypto.SecretKey.fromSeed(seed);
    var endpoint = try iroh.Resident.init(io, &seed, .{ .reachability = .discovery });
    defer endpoint.deinit() catch |err| std.log.err("iroh endpoint: {s}", .{@errorName(err)});
    var adapter = try iroh.MultiplexedAdapter.init(allocator, &endpoint);
    defer if (adapter.deinit()) |failure| std.log.err("iroh adapter: {s}", .{failure.primaryName()});
    const residents = [_]glowcap.driver.HostRuntime.ProviderRegistration{
        .{ .profile = iroh.transport_profile, .resident = adapter.multiplexed() },
    };
    const server = try glowcap.driver.listen(
        allocator,
        io,
        .{ .residents = &residents },
        iroh.transport_name,
        .{ .designator = "" },
        .{ .keyed = secret },
        .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
    );
    defer server.deinit();

    const uri = try glowcap.ocapn.model.uri.writePeer(allocator, (try server.advertisedLocator()));
    defer allocator.free(uri);
    std.debug.print("{s}\n", .{uri}); // hand this locator to partners

    try serve(server);
}

// From here, the CapTP workflow is transport-independent.
const Greeter = struct {
    pub fn handle(_: *Greeter, ht: *glowcap.driver.HostTurn, verb: []const u8, args: []const glowcap.driver.Value) !glowcap.driver.Value {
        if (!std.mem.eql(u8, verb, "greet")) return error.NoSuchMethod;
        if (args.len != 1 or args[0] != .string) return error.BadInvocation;
        return .{ .string = try std.fmt.allocPrint(ht.turn.arena, "Hello, {s}", .{args[0].string}) };
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
