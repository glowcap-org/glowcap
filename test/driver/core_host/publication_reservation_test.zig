//! Hidden publication custody unwinds on every allocation refusal.
const std = @import("std");
const Host = @import("glowcap").driver.core.Host;
const test_host = @import("../../support/core_host.zig");
const Actor = @import("../../support/actors.zig").StaticReplyActor("get", "reserved");

test "core host: durable publication reservations release custody on cancellation and allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exercise, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exercise, .{true});
}

fn exercise(allocator: std.mem.Allocator, commit: bool) !void {
    var host = test_host.init(allocator, @splat(0x65), .{});
    defer host.deinit();
    const actor = try host.vat.spawn(Actor, .{});
    defer host.vat.releaseActor(actor.local);
    const ref = try host.retainLocalCapability(actor);
    defer host.releaseCapability(ref, 1) catch unreachable;
    const roots = host.vat.actors.get(actor.local).?.roots;
    var reservation = try host.reserveDurableCapability(@splat(0x73), ref);
    defer reservation.cancel();
    try std.testing.expect(!host.publications.get(host.publication_secret, reservation.swiss.slice()).?.active);
    try std.testing.expectError(error.PublicationPending, host.reserveDurableCapability(@splat(0x73), ref));
    try std.testing.expectError(error.UnknownPublication, host.removeDurable(reservation.swiss.slice()));
    if (commit) {
        reservation.commit();
        try std.testing.expect(host.publications.get(host.publication_secret, reservation.swiss.slice()).?.active);
        var replay = try host.reserveDurableCapability(@splat(0x73), ref);
        replay.cancel(); // Existing exact publication is never withdrawn.
        try host.removeDurable(reservation.swiss.slice());
    } else reservation.cancel();
    try std.testing.expectEqual(@as(u32, 0), host.publications.count());
    try std.testing.expectEqual(roots, host.vat.actors.get(actor.local).?.roots);
}
