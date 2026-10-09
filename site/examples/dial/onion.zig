const std = @import("std");
const glowcap = @import("glowcap");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    // Dial through a running Tor daemon's SOCKS port.
    const transports: glowcap.driver.Transports = .{ .symbols = &.{.onion}, .onion = .{
        .socks = try glowcap.net.tcp.parseDesignator("127.0.0.1:9050"),
    } };
    const partner = glowcap.net.onion.locator("<56-character onion service id>");
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
