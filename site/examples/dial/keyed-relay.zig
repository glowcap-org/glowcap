const std = @import("std");
const pancake = @import("pancake");
const native_relay = @import("native_relay");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    // The key names the peer; the hint names the relay that can reach it.
    const relay_url = "wss://relay.example/relay";
    var relay: native_relay.Provider = undefined;
    switch (relay.init(io, allocator, relay_url, null, .system)) {
        .ready => {},
        .failed => return error.RelayUnavailable,
    }
    defer if (relay.deinit()) |chain| std.log.err("relay teardown failed: {s}", .{chain.primaryName()});
    const netlayers = [_]pancake.net.netlayer.Netlayer{relay.resident(.keyed).netlayer()};
    var hint_storage: [1]pancake.ocapn.model.HintEntry = undefined;
    const peer_key = "<64 lowercase hex characters from the server>";
    const partner = pancake.net.relay.keyed.locator(peer_key, relay_url, &hint_storage);
    // From here, the CapTP workflow is transport-independent.
    const session = try pancake.driver.connect(
        allocator,
        &netlayers,
        partner,
        .ephemeral,
        .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
    );
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
