//! Compile-and-lifecycle smoke for the multi-connection `driver.Host`: every
//! body analyzes, a seeded host round-trips init/deinit, and the redeem
//! answer counter stays in its synthetic range. The behavioral proofs live in
//! the three-party scenarios that dial real connections.
const std = @import("std");
const pancake = @import("pancake");

const driver = pancake.driver;

test "Host: seeded lifecycle and body analysis" {
    std.testing.refAllDecls(driver.host);
    std.testing.refAllDecls(driver.Host);
    std.testing.refAllDecls(driver.HostConnection);
    const allocator = std.testing.allocator;
    var host = driver.Host.initSeeded(allocator, undefined, &.{}, [_]u8{7} ** 32, .{});
    defer host.deinit();
    try std.testing.expect(host.next_redeem_answer >= driver.Host.REDEEM_ANSWER_BASE);
    // An unknown transport fails closed before any I/O touches the undefined io.
    try std.testing.expectError(driver.host.Error.UnknownTransport, host.dial(.{
        .transport = "nope",
        .designator = "x",
        .hints = pancake.ocapn.model.Hints.emptyFalse(),
    }));
}
