//! Compile-and-lifecycle smoke for the blocking multi-connection
//! `driver.BlockingHost`: every body analyzes, a seeded host round-trips
//! init/deinit, and an unknown transport fails closed before any I/O. The
//! behavioral proofs live in the three-party scenarios that dial real
//! connections.
const std = @import("std");
const pancake = @import("pancake");

const driver = pancake.driver;

test "Host: seeded lifecycle and body analysis" {
    std.testing.refAllDecls(driver.BlockingHost);
    std.testing.refAllDecls(driver.BlockingHost.Connection);
    std.testing.refAllDecls(driver.BlockingHost.Server);
    const allocator = std.testing.allocator;
    var host = driver.BlockingHost.initSeeded(allocator, undefined, &.{}, [_]u8{7} ** 32, .{});
    defer host.deinit();
    // An unknown transport fails closed before any I/O touches the undefined io.
    try std.testing.expectError(driver.Error.UnknownTransport, host.dial(.{
        .transport = "nope",
        .designator = "x",
        .hints = pancake.ocapn.model.Hints.emptyFalse(),
    }));
}
