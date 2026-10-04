const std = @import("std");
const glowcap = @import("glowcap");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    // Dial through the same SOCKS endpoint the listener named.
    var onion_resident = glowcap.net.onion.Resident{ .io = io, .config = .{
        .socks = "/run/tor/socks",
    } };
    const netlayers = [_]glowcap.net.netlayer.Netlayer{onion_resident.netlayer()};
    const partner = glowcap.net.onion.locator("<56-character onion service id>");
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
