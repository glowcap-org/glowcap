//! A Host send a failed turn made leaves no projection behind (ADR-0194): the
//! Port retracts the send, and the Host rolls back the export projection the
//! send's lowering minted. A successful turn keeps both.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;
const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const Capability = driver.core.Capability;

const harness = @import("harness.zig");
const frame_cap = harness.frame_cap;
const Widget = harness.Widget;
const ParkedDial = harness.ParkedDial;
const openPair = harness.openPair;
const pumpToQuiescence = harness.pumpToQuiescence;
const CapturedRef = harness.CapturedRef;

/// Sends `take` with a local capability to a far target, then fails or
/// succeeds as the verb asks.
const SendThen = struct {
    host: *Host,
    session: *HostSession,
    target: Capability,
    gift: Capability,

    pub fn handle(self: *SendThen, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        _ = try self.host.queueSendValues(self.session, self.target, "take", &.{.{ .capability = self.gift }}, arena.allocator());
        if (std.mem.eql(u8, msg.verb, "fail")) return error.Refused;
        return .{ .void = {} };
    }
};

fn exercise(verb: []const u8) !struct { exports_before: usize, exports_after: usize, pending_before: usize, pending_after: usize } {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x5a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x5b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7091", &dials);
    _ = try client.sessionPublish(pair.a, "sink", Widget, .{});
    var held = CapturedRef{};
    try server.vowOn(try server.fetch(pair.b, "sink"), .{ .ctx = &held, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const sink = try server.liftCapability(pair.b, try held.require());
    defer server.releaseCapability(sink, 1) catch unreachable;

    const widget = try server.vat.spawn(Widget, .{});
    const gift = try server.retainLocalCapability(widget);
    defer server.releaseCapability(gift, 1) catch unreachable;
    const sender = try server.vat.spawn(SendThen, .{ .host = &server, .session = pair.b, .target = sink, .gift = gift });

    const port = &pair.b.served.port;
    const exports_before = port.exports.count();
    const pending_before = port.peer.pending_send.pending().len;
    _ = server.vat.near(sender, .{ .verb = verb }) catch |err| try std.testing.expectEqual(error.Refused, err);
    return .{
        .exports_before = exports_before,
        .exports_after = port.exports.count(),
        .pending_before = pending_before,
        .pending_after = port.peer.pending_send.pending().len,
    };
}

test "core host: a failed turn's Host send leaves no projection and no queued send" {
    const result = try exercise("fail");
    try std.testing.expectEqual(result.pending_before, result.pending_after);
    try std.testing.expectEqual(result.exports_before, result.exports_after);
}

test "core host: a successful turn's Host send keeps its projection and its send" {
    const result = try exercise("ok");
    try std.testing.expectEqual(result.pending_before + 1, result.pending_after);
    try std.testing.expectEqual(result.exports_before + 1, result.exports_after);
}
