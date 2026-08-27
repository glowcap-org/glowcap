const std = @import("std");
const pancake = @import("pancake");
const harness = @import("../harness.zig");

const model = pancake.ocapn.model;
const Host = pancake.driver.core.Host;

pub fn open(
    allocator: std.mem.Allocator,
    client: *Host,
    server: *Host,
    dials: *std.ArrayList(harness.ParkedDial),
) !struct { pair: harness.Pair, widget: model.Reference } {
    const pair = try harness.openPair(allocator, client, server, "127.0.0.1:7001", dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", harness.Widget, .{});
    var fetched = harness.CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = harness.CapturedRef.record });
    try harness.pumpToQuiescence(allocator, &.{ client, server }, &.{pair}, dials);
    return .{ .pair = pair, .widget = try fetched.require() };
}
