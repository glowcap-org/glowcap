const std = @import("std");
const glowcap = @import("glowcap");
const webrtc = @import("webrtc");

// `signaling` carries the offer and each candidate to the peer the locator
// names, over a path you already hold, such as an OCapN capability both peers
// can reach. The answer comes back through `Backend.provideAnswer`.
pub fn example(io: std.Io, allocator: std.mem.Allocator, partner_uri: []const u8, signaling: webrtc.SignalingAuthority) !void {
    const partner = try glowcap.ocapn.model.uri.parsePeer(allocator, partner_uri);
    defer glowcap.ocapn.model.freePeerLocator(allocator, partner);
    var endpoint = try webrtc.Resident.init(.{});
    defer endpoint.deinit() catch |err| std.log.err("webrtc endpoint: {s}", .{@errorName(err)});
    var resident = try webrtc.CompletionResident.init(
        allocator,
        try webrtc.Backend.initBound(allocator, &endpoint, signaling, 256, 16 * 1024),
        .{},
    );
    defer resident.deinit();
    const residents = [_]glowcap.driver.HostRuntime.ProviderRegistration{
        .{ .profile = webrtc.transport_profile, .resident = resident.resident() },
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
