const std = @import("std");
const pancake = @import("pancake");

// Key designator, cleartext CapTP. Reuse a seed across restarts to keep the same key.
var keyed_resident = pancake.net.tcp.keyed.Resident{ .io = io };
const partner = "ocapn://<64 hex chars>.keyed-tcp?direct-addresses=127.0.0.1%3A9099";

const session = try pancake.driver.connectUriOwned(
    allocator,
    &.{keyed_resident.netlayer()},
    partner,
    .ephemeral,
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
