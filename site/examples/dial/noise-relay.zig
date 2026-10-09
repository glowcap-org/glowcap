const std = @import("std");
const glowcap = @import("glowcap");
const native_relay = @import("native_relay");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    // Noise_XK seals the session end to end; the relay forwards ciphertext.
    const relay_url = "wss://relay.example/relay";
    var tls = switch (native_relay.initTlsOwner(io, allocator, .system)) {
        .ready => |ready| ready.owner,
        .failed => return error.RelayUnavailable,
    };
    defer switch (tls.release()) {
        .released => {},
        .busy, .failed => std.log.err("relay TLS teardown failed", .{}),
    };
    var entropy: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randomSecure(&entropy);
    const transports: glowcap.driver.Transports = .{ .symbols = &.{.noise_relay}, .relay = .{
        .url = relay_url,
        .entropy_seed = entropy,
        .resolver_io = io,
        .tls_owner = tls,
    } };
    var hint_storage: [1]glowcap.ocapn.model.HintEntry = undefined;
    const peer_key = "<64 lowercase hex characters from the server>";
    const partner = glowcap.net.relay.noise.locator(peer_key, relay_url, &hint_storage);
    const session = try glowcap.driver.connect(
        allocator,
        io,
        transports,
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
