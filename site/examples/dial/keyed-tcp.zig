const std = @import("std");
const glowcap = @import("glowcap");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    // Key designator, cleartext CapTP. Reuse a seed across restarts to keep the same key.
    var hint_storage: [1]glowcap.ocapn.model.HintEntry = undefined;
    const peer_key = "<64 lowercase hex characters from the server>";
    const partner = glowcap.net.tcp.keyed.locator(
        peer_key,
        "127.0.0.1:9099",
        &hint_storage,
    );

    const session = try glowcap.driver.connect(
        allocator,
        io,
        .{ .symbols = &.{.keyed_tcp} },
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
