const std = @import("std");
const pancake = @import("pancake");
// In-repo builds only: `iroh` is wiring beside the package, not part of it.
// From C and the bindings this transport is `libpancake_net_transport_iroh`.
const iroh = @import("iroh");

// Discovery resolves a bare iroh node ID without an address hint.
var iroh_resident = try iroh.Resident.init(io, null, .{ .reachability = .discovery });
defer iroh_resident.deinit();
const partner = "ocapn://3b6a…da29.iroh";

const session = try pancake.driver.connectUriOwned(
    allocator,
    &.{iroh_resident.netlayer()},
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
