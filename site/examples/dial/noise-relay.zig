const std = @import("std");
const glowcap = @import("glowcap");
const native_relay = @import("native_relay");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    // Noise_XK seals the session end to end; the relay forwards ciphertext.
    const relay_url = "wss://relay.example/relay";
    var relay: native_relay.Provider = undefined;
    switch (relay.init(io, allocator, relay_url, null, .system)) {
        .ready => {},
        .failed => return error.RelayUnavailable,
    }
    defer if (relay.deinit()) |chain| std.log.err("relay teardown failed: {s}", .{chain.primaryName()});
    const netlayers = [_]glowcap.net.netlayer.Netlayer{relay.resident(.noise).netlayer()};
    var hint_storage: [1]glowcap.ocapn.model.HintEntry = undefined;
    const peer_key = "<64 lowercase hex characters from the server>";
    const partner = glowcap.net.relay.noise.locator(peer_key, relay_url, &hint_storage);
    const session = try glowcap.driver.connect(
        allocator,
        &netlayers,
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
