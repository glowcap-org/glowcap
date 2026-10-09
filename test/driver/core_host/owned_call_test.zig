//! Owned sends share routing and settlement with the public vow producers.
const std = @import("std");
const glowcap = @import("glowcap");
const h = @import("harness.zig");
const support = @import("../../support/core_host.zig");
const driver = glowcap.driver.core;
const a = std.testing.allocator;

const Echo = struct {
    calls: *usize,
    pub fn handle(self: *Echo, turn: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        defer turn.releaseValues(args);
        self.calls.* += 1;
        if (std.mem.eql(u8, verb, "break")) return error.Refused;
        return args[0];
    }
};

const RetainingActor = struct {
    host: *driver.Host,
    capability: driver.Capability,
    released: *bool,
    refused_reentry: ?*bool = null,
    spawn_on_retirement: bool = false,
    pub fn handle(_: *RetainingActor, _: *glowcap.actors.Turn, _: glowcap.actors.Message) !glowcap.ocapn.model.Argument {
        return .{ .void = {} };
    }
    pub fn deinit(self: *RetainingActor, _: std.mem.Allocator) void {
        if (self.refused_reentry) |refused| {
            refused.* = if (self.host.refuseReentry()) |_| false else |err| err == error.ReenteredHost;
        }
        if (self.spawn_on_retirement) for (0..64) |_| {
            // Native destructor effects may resize the actor index while the
            // next outer frame is opening. No borrowed cell may cross that.
            _ = self.host.vat.spawn(h.Widget, .{}) catch unreachable;
        };
        self.host.releaseCapabilityTerminal(self.capability, null);
        self.released.* = true;
    }
};

test "core host: aggregate destruction retires remote authority before actor destructors" {
    var client = support.init(a, @splat(0x57), driver.Host.Options.withFrameCap(h.frame_cap));
    var server = support.init(a, @splat(0x58), driver.Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7914", &dials);
    try pair.a.served.port.peer.importObject(7);
    const remote = try client.liftCapability(pair.a, .{ .far = glowcap.ocapn.model.FarRef.object(7) });
    var released = false;
    _ = try client.vat.spawn(RetainingActor, .{ .host = &client, .capability = remote, .released = &released });
    client.deinit();
    try std.testing.expect(released);
}

test "core host: retired actor remote release waits for the outer Vat boundary" {
    for ([_]bool{ true, false }) |eventual| {
        var client = support.init(a, @splat(0x67), driver.Host.Options.withFrameCap(h.frame_cap));
        defer client.deinit();
        var server = support.init(a, @splat(0x68), driver.Host.Options.withFrameCap(h.frame_cap));
        defer server.deinit();
        var dials: std.ArrayList(h.ParkedDial) = .empty;
        defer dials.deinit(a);
        const pair = try h.openPair(a, &client, &server, "127.0.0.1:7917", &dials);
        const published = try server.sessionPublish(pair.b, "retired-target", h.Widget, .{});
        defer server.releaseCapabilityTerminal(published, null);
        const fetched = try client.enlivenCapability(a, h.tcpSturdyref("127.0.0.1:7917", "retired-target"));
        defer fetched.deinit();
        try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
        const remote = try fetched.take();
        var released = false;
        var refused_reentry = false;
        const retaining = try client.vat.spawn(RetainingActor, .{ .host = &client, .capability = remote, .released = &released, .refused_reentry = &refused_reentry, .spawn_on_retirement = true });
        const next = try client.vat.spawn(h.Widget, .{});
        defer client.vat.releaseActor(next.local);
        var hits: usize = 0;
        const sibling = try client.vat.spawn(h.FairCounter, .{ .hits = &hits });
        defer client.vat.releaseActor(sibling.local);
        client.vat.releaseActor(retaining.local);
        if (eventual) {
            _ = try client.vat.sendFromIngress(.local, next, .{ .verb = "poke" });
            _ = try client.vat.sendFromIngress(.local, sibling, .{ .verb = "hit" });
            _ = try client.vat.driveIngressBudgeted(.local, 1);
        } else {
            _ = try client.vat.sendFromIngress(.local, sibling, .{ .verb = "hit" });
            _ = try client.vat.near(next, .{ .verb = "poke" });
        }
        try std.testing.expect(released);
        try std.testing.expect(refused_reentry);
        try std.testing.expect(client.capabilities.retainCount(remote) == null);
        try std.testing.expectEqual(@as(usize, 0), hits);
        try std.testing.expect(pair.a.sessionOpen());
        // The destructor stages GC. Its encoding/dispatch tail belongs to
        // the next top-level Host turn after the native Vat frame has closed.
        try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
        _ = try client.vat.driveIngressBudgeted(.local, 1);
        try std.testing.expectEqual(@as(usize, 1), hits);
        try std.testing.expect(pair.a.sessionOpen() and pair.b.sessionOpen());
    }
}

test "core host: owned call retains nested remote capabilities beside public completion" {
    var client = support.init(a, @splat(0x51), driver.Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = support.init(a, @splat(0x52), driver.Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7911", &dials);
    var calls: usize = 0;
    const actor = try server.sessionPublish(pair.b, "echo", driver.Hosting(Echo), .{ .inner = .{ .calls = &calls } });
    defer server.releaseCapability(actor, 1) catch unreachable;
    const fetched = try client.enlivenCapability(a, h.tcpSturdyref("127.0.0.1:7911", "echo"));
    defer fetched.deinit();
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    const target = fetched.result().ready.capability;
    const values = [_]driver.Value{.{ .list = &.{ .{ .string = "owned bytes" }, .{ .capability = target }, .{ .capability = target } } }};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const public = try client.queueSendValues(pair.a, target, "echo", &values, arena.allocator());
    const owned = try client.callCapability(a, pair.a, target, "echo", &values, 4096);
    try std.testing.expect(owned.result() == .pending);
    try client.flushSession(pair.a);
    for (0..64) |_| {
        if (!try h.shuttleAll(&.{pair})) break;
    } else return error.PumpDidNotQuiesce;
    const result = owned.result().ready.list;
    try std.testing.expectEqualStrings("owned bytes", result[0].string);
    try std.testing.expect(result[1].capability.eql(target));
    try std.testing.expect(result[2].capability.eql(target));
    owned.deinit();
    var found = false;
    while (try client.nextAction()) |action| {
        if (action == .settled and action.settled.vow_id == public) found = true;
    }
    try std.testing.expect(found);
    try client.vowRelease(public);
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "core host: owned call local routing, bounded projection, break and closed session" {
    for (0..4) |mode| {
        var client = support.init(a, @splat(0x53), driver.Host.Options.withFrameCap(h.frame_cap));
        defer client.deinit();
        var server = support.init(a, @splat(0x54), driver.Host.Options.withFrameCap(h.frame_cap));
        defer server.deinit();
        var dials: std.ArrayList(h.ParkedDial) = .empty;
        defer dials.deinit(a);
        const pair = try h.openPair(a, &client, &server, "127.0.0.1:7912", &dials);
        var calls: usize = 0;
        const target = try client.spawn(pair.a, driver.Hosting(Echo), .{ .inner = .{ .calls = &calls } });
        defer client.releaseCapabilityTerminal(target, null);
        const owned = try client.callCapability(a, pair.a, target, if (mode == 2) "break" else "echo", &.{.{ .string = "more than one byte" }}, if (mode == 1) 1 else 4096);
        defer owned.deinit();
        if (mode == 3) try client.releaseSession(pair.a) else try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
        if (mode == 0) try std.testing.expectEqualStrings("more than one byte", owned.result().ready.string) else {
            try std.testing.expect(owned.result() == .failed);
            try std.testing.expectEqualStrings(if (mode == 1) "ReplyCapacity" else if (mode == 2) "Refused" else "connection released", owned.result().failed.message);
        }
        try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
    }
}

test "core host: owned call cancellation requires no allocation and no callback survives" {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var client = support.init(failing.allocator(), @splat(0x55), driver.Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = support.init(a, @splat(0x56), driver.Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7913", &dials);
    var calls: usize = 0;
    const target = try client.spawn(pair.a, driver.Hosting(Echo), .{ .inner = .{ .calls = &calls } });
    defer client.releaseCapabilityTerminal(target, null);
    const owned = try client.callCapability(failing.allocator(), pair.a, target, "echo", &.{.{ .integer = 7 }}, 64);
    failing.fail_index = failing.alloc_index;
    const before = failing.alloc_index;
    owned.deinit();
    try std.testing.expectEqual(before, failing.alloc_index);
    try std.testing.expect(!failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
}

test "core host: owned call admission unwinds every refused allocation" {
    try std.testing.checkAllAllocationFailures(a, refusedAdmission, .{});
}

fn refusedAdmission(allocator: std.mem.Allocator) !void {
    // Enumerate this operation's object, reply and lowering storage. The
    // established Host/session allocator is covered by delivery admission tests.
    var client = support.init(a, @splat(0x59), driver.Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = support.init(a, @splat(0x5a), driver.Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7915", &dials);
    var calls: usize = 0;
    const target = try client.spawn(pair.a, driver.Hosting(Echo), .{ .inner = .{ .calls = &calls } });
    defer client.releaseCapabilityTerminal(target, null);
    const owned = try client.callCapability(allocator, pair.a, target, "echo", &.{.{ .string = "held reply" }}, 64);
    owned.deinit();
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
    // Admission queues work; neither success nor refusal drives a target effect.
    try std.testing.expectEqual(@as(usize, 0), calls);
}

const Deferring = struct {
    host: *driver.Host,
    session: *driver.HostSession,
    resolver: *u64,
    pub fn handle(self: *Deferring, turn: *glowcap.actors.Turn, _: glowcap.actors.Message) !glowcap.ocapn.model.Argument {
        self.resolver.* = try self.host.deferTurn(self.session, turn);
        return .{ .void = {} };
    }
};

const Receiving = struct {
    calls: *usize,
    poke: *u64,
    pub fn handle(self: *Receiving, turn: *driver.HostTurn, _: []const u8, args: []const driver.Value) !driver.Value {
        defer turn.releaseValues(args);
        self.calls.* += 1;
        self.poke.* = try turn.host.queueSendValues(turn.session.?, args[0].capability, "poke", &.{}, turn.turn.arena);
        return .{ .boolean = true };
    }
};

const ForwardingListener = struct {
    host: *driver.Host,
    session: *driver.HostSession,
    target: driver.Capability,
    arena: std.mem.Allocator,
    child: u64 = 0,
    failure: ?anyerror = null,

    fn complete(context: ?*anyopaque, resolution: glowcap.actors.Resolution) void {
        const self: *ForwardingListener = @ptrCast(@alignCast(context.?));
        self.forward(resolution) catch |err| {
            self.failure = err;
        };
    }
    fn forward(self: *ForwardingListener, resolution: glowcap.actors.Resolution) !void {
        if (resolution != .fulfilled) return error.UnexpectedBreak;
        const cap = try self.host.liftCapability(self.session, resolution.fulfilled.reference);
        defer self.host.releaseCapabilityTerminal(cap, null);
        self.child = try self.host.queueSendValues(self.session, self.target, "echo", &.{.{ .capability = cap }}, self.arena);
    }
};

test "core host: deferred local listener can publish its returned occurrence" {
    var client = support.init(a, @splat(0x5b), driver.Host.Options.withFrameCap(h.frame_cap));
    defer client.deinit();
    var server = support.init(a, @splat(0x5c), driver.Host.Options.withFrameCap(h.frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer dials.deinit(a);
    const pair = try h.openPair(a, &client, &server, "127.0.0.1:7916", &dials);
    var calls: usize = 0;
    var poke: u64 = 0;
    const remote = try server.sessionPublish(pair.b, "echo", driver.Hosting(Receiving), .{ .inner = .{ .calls = &calls, .poke = &poke } });
    defer server.releaseCapabilityTerminal(remote, null);
    const fetched = try client.enlivenCapability(a, h.tcpSturdyref("127.0.0.1:7916", "echo"));
    defer fetched.deinit();
    try h.pumpToQuiescence(a, &.{ &client, &server }, &.{pair}, &dials);
    var resolver: u64 = 0;
    const worker = try client.spawn(pair.a, Deferring, .{ .host = &client, .session = pair.a, .resolver = &resolver });
    defer client.releaseCapabilityTerminal(worker, null);
    const answer = try client.sendCapability(pair.a, worker, .{ .verb = "work", .args = &.{} });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var listener: ForwardingListener = .{ .host = &client, .session = pair.a, .target = fetched.result().ready.capability, .arena = arena.allocator() };
    try client.vowOn(answer, .{ .ctx = &listener, .func = ForwardingListener.complete });
    const actor = try client.vat.spawn(h.Widget, .{});
    const cap = try client.liftLocalActor(actor);
    defer client.releaseCapabilityTerminal(cap, null);
    const exports = pair.a.served.port.exports.count();
    try client.resolverFulfillValue(resolver, .{ .capability = cap }, arena.allocator());
    try std.testing.expect(listener.failure == null);
    try std.testing.expect(listener.child != 0);
    try std.testing.expectEqual(exports + 1, pair.a.served.port.exports.count());
    for (0..64) |_| {
        try client.flushSession(pair.a);
        try server.flushSession(pair.b);
        if (!try h.shuttleAll(&.{pair})) break;
    } else return error.PumpDidNotQuiesce;
    var found = false;
    while (try client.nextAction()) |action| if (action == .settled and action.settled.vow_id == listener.child) {
        found = true;
        try std.testing.expect(action.settled.value.boolean);
    };
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try client.vowRelease(listener.child);
    found = false;
    while (try server.nextAction()) |action| if (action == .settled and action.settled.vow_id == poke) {
        found = true;
        try std.testing.expectEqualStrings("poked over fed bytes", action.settled.value.string);
    };
    try std.testing.expect(found);
    try server.vowRelease(poke);
    for (0..64) |_| {
        try client.flushSession(pair.a);
        try server.flushSession(pair.b);
        if (!try h.shuttleAll(&.{pair})) break;
    } else return error.PumpDidNotQuiesce;
    // A published position keeps Port's ordinary binding until session
    // retirement; all peer-held wire occurrences must return to its baseline.
    const position = pair.a.served.port.reverse_exports.get(actor.local).?;
    try std.testing.expectEqual(@as(u64, 1), pair.a.served.port.peer.session_state.exportRefcount(.from(position)));
}
