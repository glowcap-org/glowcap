const std = @import("std");
const glowcap = @import("glowcap");

pub fn example(
    io: std.Io,
    allocator: std.mem.Allocator,
    exchange: *glowcap.net.inproc_completion.Exchange,
) !void {
    // The listening peer and dialer share this process-local switchboard.
    const partner = glowcap.net.inproc.locator("greeter");
    const session = try glowcap.driver.connect(
        allocator,
        io,
        .{ .symbols = &.{.inproc}, .inproc = exchange },
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
