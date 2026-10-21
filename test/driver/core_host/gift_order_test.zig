//! Sends from one turn to one recipient arrive in the order the turn made
//! them, even when an earlier send carries a capability from another session status-allow: event or source ordering
//! and the Node must stage it until the gift is ready.

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

const Recorder = struct {
    log: *std.ArrayList(u8),
    pub fn handle(self: *Recorder, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = turn;
        try self.log.append(std.testing.allocator, msg.verb[0]);
        return .{ .void = {} };
    }
};

const GiftThenPlain = struct {
    host: *Host,
    session: *HostSession,
    target: Capability,
    gift: Capability,

    pub fn handle(self: *GiftThenPlain, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = turn;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        _ = try self.host.queueSendValues(self.session, self.target, "gift", &.{.{ .capability = self.gift }}, arena.allocator());
        _ = try self.host.queueSendValues(self.session, self.target, "plain", &.{}, arena.allocator());
        if (std.mem.eql(u8, msg.verb, "fail")) return error.Refused;
        return .{ .void = {} };
    }
};

fn fetch(allocator: std.mem.Allocator, host: *Host, session: *HostSession, name: []const u8, hosts: []const *Host, pairs: anytype, dials: *std.ArrayList(ParkedDial)) !Capability {
    var held = CapturedRef{};
    try host.vowOn(try host.fetch(session, name), .{ .ctx = &held, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, hosts, pairs, dials);
    return host.liftCapability(session, try held.require());
}

/// Run one turn that sends `gift` then `plain` to a's sink and return what the
/// sink recorded once every Host is quiet.
fn exercise(options: Host.Options, verb: []const u8, log: *std.ArrayList(u8)) !void {
    const allocator = std.testing.allocator;
    var a = test_host.init(allocator, @as([32]u8, @splat(0x6a)), options);
    defer a.deinit();
    var b = test_host.init(allocator, @as([32]u8, @splat(0x6b)), options);
    defer b.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x6c)), options);
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const to_a = try openPair(allocator, &a, &server, "127.0.0.1:7121", &dials);
    const to_b = try openPair(allocator, &b, &server, "127.0.0.1:7122", &dials);
    _ = try a.sessionPublish(to_a.a, "sink", Recorder, .{ .log = log });
    _ = try b.sessionPublish(to_b.a, "gift", Widget, .{});
    const hosts = [_]*Host{ &a, &b, &server };
    const pairs = [_]harness.Pair{ to_a, to_b };
    const sink = try fetch(allocator, &server, to_a.b, "sink", &hosts, &pairs, &dials);
    defer server.releaseCapability(sink, 1) catch unreachable;
    const gift = try fetch(allocator, &server, to_b.b, "gift", &hosts, &pairs, &dials);
    defer server.releaseCapability(gift, 1) catch unreachable;

    const sender = try server.vat.spawn(GiftThenPlain, .{ .host = &server, .session = to_a.b, .target = sink, .gift = gift });
    _ = server.vat.near(sender, .{ .verb = verb }) catch |err| try std.testing.expectEqual(error.Refused, err);
    try pumpToQuiescence(allocator, &hosts, &pairs, &dials);
}

const profiles = [_]Host.Options{ Host.Options.withFrameCap(frame_cap), harness.nextRouteOptions() };

test "core host: a staged gift send stays ahead of the same turn's later send" {
    for (profiles) |options| {
        var log: std.ArrayList(u8) = .empty;
        defer log.deinit(std.testing.allocator);
        try exercise(options, "go", &log);
        try std.testing.expectEqualStrings("gp", log.items);
    }
}

test "core host: a failed turn retracts a staged gift send and the send queued behind it" {
    for (profiles) |options| {
        var log: std.ArrayList(u8) = .empty;
        defer log.deinit(std.testing.allocator);
        try exercise(options, "fail", &log);
        try std.testing.expectEqualStrings("", log.items);
    }
}
