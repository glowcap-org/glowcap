const std = @import("std");
const pancake = @import("pancake");

pub fn example(
    allocator: std.mem.Allocator,
    network: *pancake.net.inproc.Network,
) !void {
    // The listening peer and dialer share this process-local switchboard.
    const netlayers = [_]pancake.net.netlayer.Netlayer{network.netlayer()};
    const partner = pancake.net.inproc.locator("greeter");
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
