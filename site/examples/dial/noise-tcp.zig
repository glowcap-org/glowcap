const std = @import("std");
const pancake = @import("pancake");

// Same TCP sockets as cleartext keyed dialing; Noise_XK seals the CapTP stream.
var noise_resident = pancake.net.tcp.noise.Resident{ .io = io };
// The designator is the peer's durable key; the hint is where to dial.
const partner = "ocapn://<64 hex chars>.noise-tcp?direct-addresses=127.0.0.1%3A9099";

const session = try pancake.driver.connectUriOwned(
    allocator,
    &.{noise_resident.netlayer()},
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
