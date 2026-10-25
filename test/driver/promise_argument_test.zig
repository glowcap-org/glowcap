//! A promise received as an argument: a `desc:answer` for the partner's own
//! live question inside a deliver to a served object. The Host lifts no
//! capability promise for it, so the call fails with `UnsupportedValue`, and
//! the refusal is bounded to that call: the actor never runs, the session stays
//! open on both sides, and the next call on it is served. Before this bound
//! held, the failed projection's cleanup treated the unliftable shape as a
//! failure of its own and condemned the session as `resource_exhausted`.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const driver = glowcap.driver;
const test_host = @import("../support/core_host.zig");
const host_pair = @import("../support/host_pair.zig");
const capture = @import("../support/capture.zig");

/// Reads its first argument as a capability, which lifts it.
const Reader = struct {
    var ran: usize = 0;
    pub fn handle(_: *@This(), _: *driver.HostTurn, _: []const u8, args: driver.Args) !driver.Value {
        ran += 1;
        _ = try args.capability(0);
        return .{ .void = {} };
    }
};

const Greeter = struct {
    var ran: usize = 0;
    pub fn handle(_: *@This(), _: *driver.HostTurn, _: []const u8, _: driver.Args) !driver.Value {
        ran += 1;
        return .{ .string = "hello" };
    }
};

/// Fetch `name` and return the import the fetch added to the client session.
/// A fetch settles to a routed reference, so the import position is read from
/// the session table: the one position held after the fetch and not before.
fn importOf(host: *driver.core.Host, hs: *driver.core.HostSession, name: []const u8, pair: host_pair.Pair) !u64 {
    const before = heldImports(hs.served.port.peer);
    const vow = try host.fetch(hs, name);
    var captured: capture.CapturedRef = .{};
    try host.vowOn(vow, .{ .ctx = &captured, .func = capture.CapturedRef.record });
    try host_pair.pumpToQuiescence(&.{pair});
    if (captured.ref == null) return error.FetchUnsettled;
    const after = heldImports(hs.served.port.peer);
    for (after.items[0..after.len]) |position| {
        if (std.mem.indexOfScalar(u64, before.items[0..before.len], position) == null) return position;
    }
    return error.NoNewImport;
}

const Held = struct {
    items: [8]u64 = undefined,
    len: usize = 0,
    fn take(self: *@This(), view: session.ImportView) void {
        if (view.refcount == 0 or self.len == self.items.len) return;
        self.items[self.len] = view.position.int();
        self.len += 1;
    }
};

fn heldImports(peer: *const glowcap.ocapn.engine.Peer) Held {
    var held: Held = .{};
    session.inspect.forEachImport(&peer.session_state, &held, Held.take);
    return held;
}

/// The lowest wire position of a question `peer` asked and still holds.
fn liveQuestion(peer: *const glowcap.ocapn.engine.Peer) ?u64 {
    const Found = struct {
        position: ?u64 = null,
        fn take(self: *@This(), view: session.AnswerRowView) void {
            switch (view.position) {
                .wire => |wire| self.position = if (self.position) |c| @min(c, wire.int()) else wire.int(),
                .virtual => {},
            }
        }
    };
    var found: Found = .{};
    session.inspect.forEachOutboundAnswer(&peer.session_state, &found, Found.take);
    return found.position;
}

test "a promise argument fails its call and leaves the session serving" {
    Reader.ran = 0;
    Greeter.ran = 0;
    const gpa = std.testing.allocator;
    var dialer = test_host.init(gpa, @as([32]u8, @splat(0x22)), .{ .verify_partner = false });
    defer dialer.deinit();
    var acceptor = test_host.init(gpa, @as([32]u8, @splat(0x33)), .{ .verify_partner = false });
    defer acceptor.deinit();
    const pair = try host_pair.openPair(&dialer, &acceptor, "127.0.0.1:9001");
    _ = try pair.b.served.publish(&pair.b.host.vat, "reader", driver.core.Hosting(Reader), .{ .inner = .{} });
    _ = try pair.b.served.publish(&pair.b.host.vat, "greeter", driver.core.Hosting(Greeter), .{ .inner = .{} });
    const reader = try importOf(&dialer, pair.a, "reader", pair);
    const greeter = try importOf(&dialer, pair.a, "greeter", pair);
    const client = pair.a.served.port.peer;

    // Ask a question the client holds open: a greet with an answer position.
    try client.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(greeter) },
        .args = &.{.{ .symbol = "greet" }},
        .answer = .from(7),
    } });
    try client.stepToIdle();
    try host_pair.pumpToQuiescence(&.{pair});
    try std.testing.expectEqual(@as(usize, 1), Greeter.ran);
    const question = liveQuestion(client) orelse return error.NoLiveQuestion;

    // The partner's own live question, passed as an argument the actor reads.
    try client.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(reader) },
        .args = &.{ .{ .symbol = "read" }, .{ .reference = .{ .promise = .{ .answer_position = .from(question) } } } },
    } });
    try client.stepToIdle();
    try host_pair.pumpToQuiescence(&.{pair});
    try std.testing.expectEqual(@as(usize, 0), Reader.ran);
    try std.testing.expectEqual(.active, pair.b.lifecyclePhase());
    try std.testing.expectEqual(.active, pair.a.lifecyclePhase());
    try std.testing.expect(pair.b.lastAbort() == null);

    // The session still serves.
    try client.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(greeter) },
        .args = &.{.{ .symbol = "greet" }},
    } });
    try client.stepToIdle();
    try host_pair.pumpToQuiescence(&.{pair});
    try std.testing.expectEqual(@as(usize, 2), Greeter.ran);
    try std.testing.expectEqual(.active, pair.b.lifecyclePhase());
}
