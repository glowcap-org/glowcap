//! A held capability whose home session was released is a closed connection,
//! not an unknown reference. `Registry.liveTarget` decides: a retired row the
//! application still holds is `CapabilityClosed` (the `closed` class), and an
//! id the Host never issued or has fully released is `UnknownCapability`.
//! Every verb that names the capability as its target, or retains it, reads
//! that one answer, including a promise fulfilled to it and a turn or
//! pending-work call that has no session of its own. A turn with no session
//! takes its route from `routing.applicationTarget`, so a promise there routes
//! by its own state: an unsettled one queues a send, a tell, or an answerless
//! forward until it settles and refuses an observed forward or call as
//! `NotResolved`, a broken one is `PromiseBroken`, one fulfilled to a local
//! actor delivers, and one fulfilled to data is `UncallableTarget`.
//!
//! The `sessions.get(...) orelse return error.CapabilityClosed` guards in
//! `applicationTarget` and `routeCapability` have no test: a session release
//! retires its rows and breaks its pending promises before it removes the
//! session, so no live row names a session that is gone.

const std = @import("std");
const glowcap = @import("glowcap");
const h = @import("harness.zig");
const test_host = @import("../../support/core_host.zig");

const core = glowcap.driver.core;
const model = glowcap.ocapn.model;
const a = std.testing.allocator;

test "core host closed home: verbs naming a held capability report it closed" {
    var host = test_host.init(a, @splat(0x61), .{ .thread_policy = .unchecked });
    defer host.deinit();
    var exporter = test_host.init(a, @splat(0x62), .{ .thread_policy = .unchecked });
    defer exporter.deinit();
    var bystander = test_host.init(a, @splat(0x63), .{ .thread_policy = .unchecked });
    defer bystander.deinit();
    const home = (try h.host_pair.openPair(&host, &exporter, "127.0.0.1:7921")).a;
    const other = (try h.host_pair.openPair(&host, &bystander, "127.0.0.1:7922")).a;
    try home.served.port.peer.importObject(7);
    const remote = try host.liftCapability(home, .{ .far = model.FarRef.object(7) });
    try host.releaseSession(home);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.CapabilityClosed, host.sendApplicationValues(remote, "poke", &.{}, arena.allocator()));
    try std.testing.expectError(error.CapabilityClosed, host.tellApplicationValues(remote, "poke", &.{}, arena.allocator()));
    try std.testing.expectError(error.CapabilityClosed, host.sendValues(other, remote, "poke", &.{}, arena.allocator()));
    try std.testing.expectError(error.CapabilityClosed, host.routeCapability(other, remote, .any_target));
    try std.testing.expectError(error.CapabilityClosed, host.listenToCapability(other, remote));
    try std.testing.expectError(error.CapabilityClosed, host.resolveCapability(other, remote));
    try std.testing.expectError(error.CapabilityClosed, host.settledCapability(remote));
    try std.testing.expectError(error.CapabilityClosed, host.retainCapability(remote));
    try std.testing.expectEqual(core.HostFailure.Kind.closed, core.HostFailure.classify(error.CapabilityClosed));

    // As an argument the reference is stale, toward a local or a live remote target.
    var counts: Counts = .initFill(0);
    const local = try spawn(&host, Target, .{ .counts = &counts });
    defer host.releaseCapabilityTerminal(local, null);
    try other.served.port.peer.importObject(8);
    const live = try host.liftCapability(other, .{ .far = model.FarRef.object(8) });
    defer host.releaseCapabilityTerminal(live, null);
    const argument = [_]core.Value{.{ .capability = remote }};
    try std.testing.expectError(error.UnknownCapability, host.sendApplicationValues(local, "poke", &argument, arena.allocator()));
    try std.testing.expectError(error.UnknownCapability, host.sendApplicationValues(live, "poke", &argument, arena.allocator()));
    try std.testing.expectEqual(Counts.initFill(0).values, counts.values);

    // The handle's outstanding unit still settles. After that the id is stale.
    try host.releaseCapability(remote, 1);
    try std.testing.expectError(error.UnknownCapability, host.sendApplicationValues(remote, "poke", &.{}, arena.allocator()));
    try std.testing.expectError(error.UnknownCapability, host.retainCapability(remote));
}

test "core host closed home: an id the Host never issued stays unknown" {
    var host = test_host.init(a, @splat(0x64), .{ .thread_policy = .unchecked });
    defer host.deinit();
    var partner = test_host.init(a, @splat(0x65), .{ .thread_policy = .unchecked });
    defer partner.deinit();
    const session = (try h.host_pair.openPair(&host, &partner, "127.0.0.1:7923")).a;
    const stale = host.capabilities.refFromRaw(0);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownCapability, host.sendApplicationValues(stale, "poke", &.{}, arena.allocator()));
    try std.testing.expectError(error.UnknownCapability, host.tellApplicationValues(stale, "poke", &.{}, arena.allocator()));
    try std.testing.expectError(error.UnknownCapability, host.sendValues(session, stale, "poke", &.{}, arena.allocator()));
    try std.testing.expectError(error.UnknownCapability, host.listenToCapability(session, stale));
    try std.testing.expectError(error.UnknownCapability, host.retainCapability(stale));
    try std.testing.expectEqual(core.HostFailure.Kind.not_found, core.HostFailure.classify(error.UnknownCapability));
}

/// How the giver answers: with the gift, with data, deferred, or refused.
/// `settle` gives too, and the test asks for the promise only after the
/// answer arrived, so the Host has not yet finished settling it.
const Mode = enum { give, data, hold, settle, refuse };

const Giver = struct {
    gift: core.Capability,
    mode: Mode,
    calls: *usize,
    resolver: *u64,

    pub fn handle(self: *Giver, turn: *core.HostTurn, _: ?[]const u8, args: core.Args) !core.Value {
        defer turn.releaseArguments(args);
        self.calls.* += 1;
        switch (self.mode) {
            .give, .settle => return .{ .capability = self.gift },
            .data => return .{ .string = "data" },
            .hold => {
                self.resolver.* = try turn.deferAnswer();
                return .{ .void = {} };
            },
            .refuse => return error.Refused,
        }
    }
};

/// Each path names its own verb, so a count says which path delivered.
const Verb = enum { send, tell, forward, call };
const Counts = std.enums.EnumArray(Verb, usize);

/// The actor a fulfilled promise names.
const Target = struct {
    counts: *Counts,

    pub fn handle(self: *Target, turn: *core.HostTurn, verb: ?[]const u8, args: core.Args) !core.Value {
        defer turn.releaseArguments(args);
        const named = std.meta.stringToEnum(Verb, verb orelse "") orelse return error.UnexpectedVerb;
        self.counts.getPtr(named).* += 1;
        return .{ .void = {} };
    }
};

/// What each sessionless path returned for one target: null is success.
const Seen = struct {
    ran: bool = false,
    send: ?anyerror = null,
    tell: ?anyerror = null,
    forward: ?anyerror = null,
};

/// A local turn has no session, so its send, tell, and forward take the
/// target's route from the Host. `forward_only` leaves just the forward.
const Probe = struct {
    target: core.Capability,
    seen: *Seen,
    forward_only: bool = false,

    pub fn handle(self: *Probe, turn: *core.HostTurn, _: ?[]const u8, args: core.Args) !core.Value {
        defer turn.releaseArguments(args);
        self.seen.ran = true;
        if (!self.forward_only) {
            if (turn.send(self.target, "send", &.{})) |_| {} else |err| self.seen.send = err;
            if (turn.tell(self.target, "tell", &.{})) |_| {} else |err| self.seen.tell = err;
        }
        if (turn.forward(self.target, "forward", &.{})) |_| {} else |err| self.seen.forward = err;
        return .{ .void = {} };
    }
};

fn spawn(host: *core.Host, comptime B: type, initial: B) !core.Capability {
    const reservation = try host.reserveFreshCapability(null);
    const actor = try host.vat.spawn(core.Hosting(B), .{ .inner = initial });
    return host.adoptReservedLocalCapability(reservation, actor);
}

/// `answerless_forward` is the forward from a turn that arrived as a tell,
/// which has no answer to carry.
const Expected = struct {
    send: ?anyerror,
    tell: ?anyerror,
    forward: ?anyerror,
    call: ?anyerror,
    answerless_forward: ?anyerror,
};

/// Run every sessionless path at `target` and compare each outcome.
fn expectSessionless(host: *core.Host, target: core.Capability, expected: Expected) !void {
    var seen: Seen = .{};
    const probe = try spawn(host, Probe, .{ .target = target, .seen = &seen });
    defer host.releaseCapabilityTerminal(probe, null);
    const turn_call = try host.callLocalCapability(a, probe, "probe", &.{}, 4096);
    defer turn_call.deinit();
    try host.vat.drive();
    try std.testing.expect(seen.ran);
    try std.testing.expectEqual(expected.send, seen.send);
    try std.testing.expectEqual(expected.tell, seen.tell);
    try std.testing.expectEqual(expected.forward, seen.forward);

    var told: Seen = .{};
    const forwarder = try spawn(host, Probe, .{ .target = target, .seen = &told, .forward_only = true });
    defer host.releaseCapabilityTerminal(forwarder, null);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try host.tellApplicationValues(forwarder, "probe", &.{}, arena.allocator());
    try host.vat.drive();
    try std.testing.expect(told.ran);
    try std.testing.expectEqual(expected.answerless_forward, told.forward);

    var lease = try host.admitPendingWork();
    defer lease.complete();
    const called: ?anyerror = if (lease.call(a, target, "call", &.{}, 4096, null)) |call| blk: {
        call.deinit();
        break :blk null;
    } else |err| err;
    try std.testing.expectEqual(expected.call, called);
    try host.vat.drive();
}

/// The settlement state of the promise `promise` names.
fn expectState(host: *core.Host, promise: core.Capability, expected: anytype) !void {
    const row = host.capability_promises.get(host.capabilities.resolve(promise).?.deferred).?;
    const Tag = std.meta.Tag(@TypeOf(row.state));
    try std.testing.expectEqual(@as(Tag, expected), std.meta.activeTag(row.state));
}

fn counted(send: usize, tell: usize, forward: usize, call: usize) Counts {
    return .init(.{ .send = send, .tell = tell, .forward = forward, .call = call });
}

test "core host closed home: a sessionless turn and a pending-work call report it closed" {
    var host = test_host.init(a, @splat(0x66), .{ .thread_policy = .unchecked });
    defer host.deinit();
    var exporter = test_host.init(a, @splat(0x67), .{ .thread_policy = .unchecked });
    defer exporter.deinit();
    const home = (try h.host_pair.openPair(&host, &exporter, "127.0.0.1:7924")).a;
    try home.served.port.peer.importObject(7);
    const remote = try host.liftCapability(home, .{ .far = model.FarRef.object(7) });
    defer host.releaseCapabilityTerminal(remote, null);
    try host.releaseSession(home);

    const closed = error.CapabilityClosed;
    try expectSessionless(&host, remote, .{ .send = closed, .tell = closed, .forward = closed, .call = closed, .answerless_forward = closed });
}

test "core host closed home: a promise fulfilled to the reference reports it closed" {
    var host = test_host.init(a, @splat(0x68), .{ .thread_policy = .unchecked });
    defer host.deinit();
    var exporter = test_host.init(a, @splat(0x69), .{ .thread_policy = .unchecked });
    defer exporter.deinit();
    var bystander = test_host.init(a, @splat(0x6a), .{ .thread_policy = .unchecked });
    defer bystander.deinit();
    const pair = try h.host_pair.openPair(&host, &exporter, "127.0.0.1:7925");
    const other = (try h.host_pair.openPair(&host, &bystander, "127.0.0.1:7926")).a;

    var counts: Counts = .initFill(0);
    const gift = try spawn(&exporter, Target, .{ .counts = &counts });
    defer exporter.releaseCapabilityTerminal(gift, null);
    var giver_calls: usize = 0;
    var resolver: u64 = 0;
    const giver = try spawn(&exporter, Giver, .{ .gift = gift, .mode = .give, .calls = &giver_calls, .resolver = &resolver });
    defer exporter.releaseCapabilityTerminal(giver, null);
    const swiss = try exporter.publishDurableCapability(@splat(0x45), giver);
    var fetched: h.CapturedRef = .{};
    try host.vowOn(try host.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = h.CapturedRef.record });
    try h.host_pair.pumpToQuiescence(&.{pair});
    const remote_giver = try host.liftCapability(pair.a, try fetched.require());
    defer host.releaseCapabilityTerminal(remote_giver, null);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const promise = try host.vowCapability(try host.sendValues(pair.a, remote_giver, "give", &.{}, arena.allocator()));
    defer host.releaseCapabilityTerminal(promise, null);
    try h.host_pair.pumpToQuiescence(&.{pair});
    const row = host.capability_promises.get(host.capabilities.resolve(promise).?.deferred).?;
    try std.testing.expect(row.state == .fulfilled);
    try std.testing.expect(host.capabilities.resolve(row.state.fulfilled).? == .remote);
    try host.releaseSession(pair.a);

    try std.testing.expectError(error.CapabilityClosed, host.settledCapability(promise));
    try std.testing.expectError(error.CapabilityClosed, host.listenToCapability(other, promise));
    try std.testing.expectError(error.CapabilityClosed, host.sendValues(other, promise, "poke", &.{}, arena.allocator()));
    try std.testing.expectError(error.CapabilityClosed, host.sendApplicationValues(promise, "poke", &.{}, arena.allocator()));
    try std.testing.expectEqual(Counts.initFill(0).values, counts.values);
}

test "core host closed home: a sessionless promise target routes by its own state" {
    for (std.enums.values(Mode)) |mode| {
        var host = test_host.init(a, @splat(0x6b), .{ .thread_policy = .unchecked });
        defer host.deinit();
        var partner = test_host.init(a, @splat(0x6c), .{ .thread_policy = .unchecked });
        defer partner.deinit();
        const pair = try h.host_pair.openPair(&host, &partner, "127.0.0.1:7927");
        var dials: std.ArrayList(h.ParkedDial) = .empty;
        defer h.deinitParked(a, &dials);

        var counts: Counts = .initFill(0);
        const gift = try spawn(&host, Target, .{ .counts = &counts });
        defer host.releaseCapabilityTerminal(gift, null);
        var giver_calls: usize = 0;
        var resolver: u64 = 0;
        const giver = try spawn(&host, Giver, .{ .gift = gift, .mode = mode, .calls = &giver_calls, .resolver = &resolver });
        defer host.releaseCapabilityTerminal(giver, null);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const vow = try host.sendValues(pair.a, giver, "give", &.{}, arena.allocator());
        // A promise asked for after its vow settled stages the held answer,
        // and the Host's next action drain finishes settling it.
        if (mode == .settle) try h.pumpToQuiescence(a, &.{ &host, &partner }, &.{pair}, &dials);
        const promise = try host.vowCapability(vow);
        defer host.releaseCapabilityTerminal(promise, null);
        if (mode != .settle) try h.pumpToQuiescence(a, &.{ &host, &partner }, &.{pair}, &dials);

        const not_resolved = error.NotResolved;
        switch (mode) {
            .give => {
                try expectState(&host, promise, .fulfilled);
                const row = host.capability_promises.get(host.capabilities.resolve(promise).?.deferred).?;
                try std.testing.expect(host.capabilities.resolve(row.state.fulfilled).? == .local);
                try expectSessionless(&host, promise, .{ .send = null, .tell = null, .forward = null, .call = null, .answerless_forward = null });
                try std.testing.expectEqual(counted(1, 1, 2, 1).values, counts.values);
            },
            .settle, .hold => {
                if (mode == .settle) try expectState(&host, promise, .settling) else try expectState(&host, promise, .pending);
                // A send, a tell, and an answerless forward queue on the
                // promise. A forward or call that observes an answer cannot.
                try expectSessionless(&host, promise, .{ .send = null, .tell = null, .forward = not_resolved, .call = not_resolved, .answerless_forward = null });
                try std.testing.expectEqual(Counts.initFill(0).values, counts.values);
                if (mode == .hold) try host.resolverFulfillValue(resolver, .{ .capability = gift }, arena.allocator());
                try h.pumpToQuiescence(a, &.{ &host, &partner }, &.{pair}, &dials);
                try expectState(&host, promise, .fulfilled);
                try std.testing.expectEqual(counted(1, 1, 1, 0).values, counts.values);
            },
            .data => {
                try expectState(&host, promise, .fulfilled_data);
                const uncallable = error.UncallableTarget;
                try expectSessionless(&host, promise, .{ .send = uncallable, .tell = uncallable, .forward = uncallable, .call = uncallable, .answerless_forward = uncallable });
                try std.testing.expectEqual(Counts.initFill(0).values, counts.values);
            },
            .refuse => {
                try expectState(&host, promise, .broken);
                const broken = error.PromiseBroken;
                try expectSessionless(&host, promise, .{ .send = broken, .tell = broken, .forward = broken, .call = broken, .answerless_forward = broken });
                try std.testing.expectEqual(Counts.initFill(0).values, counts.values);
            },
        }
        // Nothing a probe sent reached the giver.
        try std.testing.expectEqual(@as(usize, 1), giver_calls);
    }
}
