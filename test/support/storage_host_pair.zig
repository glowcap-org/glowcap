//! Storage-driven CapTP probe calls use the same Host pair and bounded executor.
const h = @import("../loam/access/hosting_fixture.zig");
const pairs = @import("host_pair.zig");
const captures = @import("capture.zig");
const model = h.f.glowcap.ocapn.model;

pub fn send(client: *h.driver.Host, pair: pairs.Pair, target: model.Reference, verb: []const u8, args: []const model.Argument, capture: anytype) !void {
    try client.vowOn(try client.send(pair.a, target, .{ .verb = verb, .args = args }), .{ .ctx = capture, .func = @TypeOf(capture.*).record });
    try pairs.pumpToQuiescence(&.{pair});
}

pub fn fetchCapture(server: anytype, client: *h.driver.Host, pair: pairs.Pair, secret: h.loam.hosting.publication.Entropy) !captures.CapturedRef {
    var captured: captures.CapturedRef = .{};
    const name = h.driver.Host.DurableSwiss.fromEntropy(secret);
    try client.vowOn(try client.fetch(pair.a, name.slice()), .{ .ctx = &captured, .func = captures.CapturedRef.record });
    try pairs.pumpToQuiescence(&.{pair});
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    return captured;
}

pub fn fetch(server: anytype, client: *h.driver.Host, pair: pairs.Pair, secret: h.loam.hosting.publication.Entropy) !model.Reference {
    const captured = try fetchCapture(server, client, pair, secret);
    return captured.require();
}
