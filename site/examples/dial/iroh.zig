const std = @import("std");
const glowcap = @import("glowcap");
const iroh = @import("iroh");

pub fn example(io: std.Io, allocator: std.mem.Allocator, partner_uri: []const u8) !void {
    const partner = try glowcap.ocapn.model.uri.parsePeer(allocator, partner_uri);
    defer glowcap.ocapn.model.freePeerLocator(allocator, partner);
    var endpoint = try iroh.Resident.init(io, null, .{ .reachability = .discovery });
    defer endpoint.deinit() catch |err| std.log.err("iroh endpoint: {s}", .{@errorName(err)});
    var adapter = try iroh.MultiplexedAdapter.init(allocator, &endpoint);
    defer if (adapter.deinit()) |failure| std.log.err("iroh adapter: {s}", .{failure.primaryName()});
    const residents = [_]glowcap.driver.HostRuntime.ProviderRegistration{
        .{ .profile = iroh.transport_profile, .resident = adapter.multiplexed() },
    };

    const session = try glowcap.driver.connect(
        allocator,
        io,
        .{ .residents = &residents },
        partner,
        .ephemeral,
        .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
    );
    // From here, the CapTP workflow is transport-independent.
    defer session.deinit();

    const greeter = try session.fetch("greeter"); // a capability this peer published
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const settled = try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena.allocator());
    switch (settled) {
        .fulfilled => |value| std.debug.print("{s}\n", .{value.string}),
        .broken => |reason| std.debug.print("the greeter refused: {s}\n", .{reason}),
    }
}
