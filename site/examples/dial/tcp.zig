const std = @import("std");
const pancake = @import("pancake");

// Plain TCP uses a cleartext `host:port` locator.
var tcp_resident = pancake.net.tcp.Resident{ .io = io };
const partner = pancake.net.tcp.at(designator);

const session = try pancake.driver.connect(
    allocator,
    &.{tcp_resident.netlayer()},
    partner,
    .ephemeral,
    // Never leave a network wait unbounded.
    .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
);
defer session.deinit();

const greeter = try session.fetch("greeter"); // an opaque capability, by name
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const settled = try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena.allocator());
switch (settled) {
    .fulfilled => |value| std.debug.print("{s}\n", .{value.string}),
    .broken => |reason| std.debug.print("the greeter refused: {s}\n", .{reason}),
}
