const std = @import("std");
const pancake = @import("pancake");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    // pancake starts no Tor. Name an already-running daemon's SOCKS and control endpoints.
    var onion_resident = pancake.net.onion.Resident{ .io = io, .config = .{
        .socks = "/run/tor/socks",
        .control_endpoint = "/run/tor/control",
    } };
    const server = try pancake.driver.listen(
        allocator,
        onion_resident.netlayer(),
        .{ .designator = "" },
        .ephemeral,
        .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
    );
    defer server.deinit();

    const uri = try pancake.ocapn.model.uri.writePeer(allocator, (try server.advertisedLocator()));
    defer allocator.free(uri);
    std.debug.print("{s}\n", .{uri}); // hand this locator to partners

    var service_key_storage: [256]u8 = undefined;
    const key_len = (try server.restorationState(&service_key_storage)) orelse
        return error.RestorationStateUnavailable;
    const service_key = service_key_storage[0..key_len];
    _ = service_key; // persist securely to restore this service

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
