//! Who owns a lifted tree decides what a refused lift owes. A borrowed tree (a
//! near call's arguments or reply) stays with its live caller: the lift undoes
//! only its own claims, sends nothing, consumes no route, and leaves the session
//! serving. A partner or queued tree was consumed, so a failure retires every
//! observation through exact wire GC. Each arm below asserts the import row,
//! the Host identity, the registry, the Node route, the outbound queue, and the
//! caller's retry, so a cleanup that touches the wrong owner fails here.

const std = @import("std");
const glowcap = @import("glowcap");
const shapes = @import("../../support/depth_shapes.zig");
const test_host = @import("../../support/core_host.zig");
const host_pair = @import("../../support/host_pair.zig");
const capture = @import("../../support/capture.zig");
const fixture = @import("borrowed_lift_fixture.zig");
const node_harness = @import("../../engine/node/harness.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;
const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const allocator = std.testing.allocator;
const Fixture = fixture.Fixture;
const far7 = fixture.far7;
const LocalActor = fixture.LocalActor;
const Greeter = fixture.Greeter;
const Probe = fixture.Probe;
const inlineGive = fixture.inlineGive;
const chain = fixture.chain;
const importOf = fixture.importOf;
const partnerImport = fixture.partnerImport;

test "a borrowed lift past the ceiling leaves references before, after, and inside the refused subtree with the caller" {
    var f: Fixture = undefined;
    try f.init(0xA0, "127.0.0.1:9890");
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = try chain(arena);
    const inside = [_]model.Argument{ far7, deep };
    const layouts = [_][]const model.Argument{
        &.{ far7, deep },
        &.{ deep, far7 },
        &.{ .{ .list = &inside }, far7 },
    };

    for (layouts) |layout| {
        try f.peer().importObject(7);
        const before = f.snapshot(7);
        try std.testing.expectEqual(@as(u64, 1), before.refcount);
        try std.testing.expectError(error.ValueTooDeep, f.lift(arena, layout, .borrowed));
        try f.expectKept(before, 7);

        // The retained input retries, and its one final release retires it.
        const retry = try f.lift(arena, &.{far7}, .borrowed);
        try std.testing.expectEqual(@as(u64, 1), f.state().importRefcount(.from(7)));
        try f.host.releaseCapability(retry[0].capability, 1);
        try std.testing.expect(!f.state().holdsImport(.from(7)));
        try std.testing.expect(f.peer().hasOutbound());
    }
}

test "a borrowed lift that refuses for another reason keeps the session and every reference" {
    var f: Fixture = undefined;
    try f.init(0xA2, "127.0.0.1:9891");
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try f.peer().importObject(7);
    const before = f.snapshot(7);
    // Position 99 names no import this session holds, so the lift refuses it
    // after position 7 lifted. A consumed cleanup would re-lift 99 and
    // condemn the healthy session.
    const unheld: model.Argument = .{ .reference = .{ .far = model.FarRef.object(99) } };
    const refusal = f.lift(arena, &.{ far7, unheld }, .borrowed);
    try std.testing.expect(std.meta.isError(refusal));
    try f.expectKept(before, 7);
    try std.testing.expect(f.session.sessionOpen());

    const retry = try f.lift(arena, &.{far7}, .borrowed);
    try f.host.releaseCapability(retry[0].capability, 1);
    try std.testing.expect(!f.state().holdsImport(.from(7)));
}

test "a borrowed lift that cannot allocate undoes fresh and reused claims alike" {
    var f: Fixture = undefined;
    try f.init(0xA4, "127.0.0.1:9892");
    defer f.deinit();
    // Nine references spill the receipt list, so a failing arena refuses after
    // eight claims: one fresh identity and seven reused ones.
    const count = 9;
    var args: [count]model.Argument = @splat(far7);
    for (0..count) |_| try f.peer().importObject(7);
    const before = f.snapshot(7);
    try std.testing.expectEqual(@as(u64, count), before.refcount);

    var refused: usize = 0;
    var index: usize = 0;
    while (index < 16) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = index });
        var arena_state = std.heap.ArenaAllocator.init(failing.allocator());
        defer arena_state.deinit();
        if (f.lift(arena_state.allocator(), &args, .borrowed)) |lifted| {
            for (lifted) |value| try f.host.releaseCapability(value.capability, 1);
            // Success claimed every retain, so rebuild the import for the next try.
            try std.testing.expect(!f.state().holdsImport(.from(7)));
            for (0..count) |_| try f.peer().importObject(7);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            refused += 1;
            try std.testing.expectEqual(before, f.snapshot(7));
            try std.testing.expect(f.session.sessionOpen());
        }
    }
    try std.testing.expect(refused != 0);
}

test "a borrowed lift of an identity the caller already holds returns only its own wire claim" {
    var f: Fixture = undefined;
    try f.init(0xB4, "127.0.0.1:9900");
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = try chain(arena);

    // Two wire occurrences: the caller's handle claims one, the refused lift
    // would claim the other as a reused identity.
    try f.peer().importObject(7);
    try f.peer().importObject(7);
    const held = try f.lift(arena, &.{far7}, .borrowed);
    const before = f.snapshot(7);
    try std.testing.expectEqual(@as(u64, 1), before.lifted);

    try std.testing.expectError(error.ValueTooDeep, f.lift(arena, &.{ far7, deep }, .borrowed));
    try f.expectKept(before, 7);

    const retry = try f.lift(arena, &.{far7}, .borrowed);
    try std.testing.expectEqual(@as(u64, 2), f.snapshot(7).lifted);
    try f.host.releaseCapability(retry[0].capability, 1);
    try f.host.releaseCapability(held[0].capability, 1);
    try std.testing.expect(!f.state().holdsImport(.from(7)));
}

test "a borrowed lift gives a held-back retain back to the stored resolution's hold" {
    var f: Fixture = undefined;
    try f.init(0xA6, "127.0.0.1:9893");
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = try chain(arena);

    try f.peer().importObject(7);
    f.state().imports.holdForResolution(.from(7));
    try f.state().imports.decrement(.from(7), 1);
    try std.testing.expectEqual(@as(u64, 0), f.state().importReleasable(.from(7)));
    const before = f.snapshot(7);

    try std.testing.expectError(error.ValueTooDeep, f.lift(arena, &.{ far7, deep }, .borrowed));
    try f.expectKept(before, 7);
    try std.testing.expectEqual(@as(u64, 1), f.state().imports.sessionHeld(.from(7)));
    // The hold still owes the wire the retain it owed before the lift.
    const owed = f.state().imports.releaseResolutionHold(.from(7));
    try std.testing.expectEqual(@as(u64, 1), owed);
    f.state().imports.releaseSessionHeld(.from(7), owed);
    try std.testing.expect(!f.state().holdsImport(.from(7)));
}

test "a borrowed lift of a local actor, then a refusal, leaves no registry row" {
    var f: Fixture = undefined;
    try f.init(0xAA, "127.0.0.1:9895");
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = try chain(arena);

    const exported = try f.session.served.publish(&f.host.vat, "local", LocalActor, .{});
    const near: model.Argument = exported.arg();
    const before = f.snapshot(7);

    try std.testing.expectError(error.ValueTooDeep, f.lift(arena, &.{ near, deep }, .borrowed));
    try std.testing.expectEqual(before.live, f.host.capabilities.liveCount());
    try std.testing.expect(!f.host.capabilities.hasTarget(.{ .local = exported.ref.local }));
    try std.testing.expect(f.host.vat.hasActor(exported.ref.local));

    const retry = try f.lift(arena, &.{near}, .borrowed);
    try std.testing.expectEqual(before.live + 1, f.host.capabilities.liveCount());
    try f.host.releaseCapability(retry[0].capability, 1);
    try std.testing.expectEqual(before.live, f.host.capabilities.liveCount());
}

/// A third party: a second session of the Host's own Node, to a partner that
/// exports `far 7`. A signed give redeemed against it mints a Node route the
/// Host lifts through the first session, the way a handoff arrives.
fn nextNonFlush(node: *glowcap.ocapn.engine.Node) !glowcap.ocapn.engine.Node.Action {
    while (node.nextAction()) |action| if (action != .flush) return action;
    return error.MissingNodeAction;
}

const Exporter = struct {
    other: Host,
    pair: host_pair.Pair,

    fn init(self: *Exporter, seed: u8, designator: []const u8, f: *Fixture) !void {
        self.other = test_host.init(allocator, @as([32]u8, @splat(seed)), .{ .thread_policy = .unchecked });
        self.pair = try host_pair.openPair(&f.host, &self.other, designator);
        try self.state().registerImport(.from(7));
    }

    fn deinit(self: *Exporter) void {
        self.other.deinit();
    }

    fn state(self: *Exporter) *glowcap.ocapn.session.Session {
        return &self.pair.a.served.port.peer.session_state;
    }

    /// Redeem a fresh give for `far 7` and return the route that names it.
    fn route(self: *Exporter, f: *Fixture, answer: u64) !model.Argument {
        // The harness's steps with the Host's real sessions: each session also
        // queues a flush the white-box mint has no use for.
        const node = &f.host.node;
        const give = try node_harness.testGiveBytes(allocator);
        defer allocator.free(give);
        try node.acceptGive(f.session.peer_handle, try node_harness.holdAnswer(node, f.session.peer_handle, answer), give, "ocapn://127.0.0.1%3A9055.tcp");
        // The first redemption dials the exporter. Later gifts to it reuse the
        // open session and park their withdraw at once.
        while (node.nextAction()) |action| switch (action) {
            .dial => |dial| _ = try node.exporterDialed(dial.pending, 0, self.pair.a.peer_handle),
            .flush => {},
            else => return error.UnexpectedNodeAction,
        };
        const withdraw = node_harness.pendingWithdrawAnswer(node, self.pair.a.peer_handle);
        if (!try node.claimResolve(self.pair.a.peer_handle, withdraw, .{ .far = 7 })) return error.NotClaimed;
        const id = (try nextNonFlush(node)).settle.route_id;
        return .{ .reference = .{ .routed = .{ .id = id } } };
    }
};

test "a refused borrowed lift leaves a redeemed route live for the retry, and one success consumes it once" {
    var f: Fixture = undefined;
    try f.init(0xA8, "127.0.0.1:9894");
    defer f.deinit();
    var third: Exporter = undefined;
    try third.init(0xE1, "127.0.0.1:9914", &f);
    defer third.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = try chain(arena);

    const route = try third.route(&f, 71);
    const live = f.host.capabilities.liveCount();
    const refcount = third.state().importRefcount(.from(7));

    try std.testing.expectError(error.ValueTooDeep, f.lift(arena, &.{ route, deep }, .borrowed));
    try std.testing.expect(f.host.node.redeemedRouteId(route.reference) != null);
    try std.testing.expectEqual(live, f.host.capabilities.liveCount());
    try std.testing.expectEqual(refcount, third.state().importRefcount(.from(7)));
    try std.testing.expectEqual(@as(?u64, null), third.state().hostCapabilityFor(.from(7)));
    try std.testing.expect(f.peer().lastAbort() == null);

    // The retry consumes the route once. The same route twice in one tree is
    // one observation of one import identity, so it commits without a second
    // consumption.
    const twice = try f.lift(arena, &.{ route, route }, .borrowed);
    try std.testing.expect(f.host.node.redeemedRouteId(route.reference) == null);
    try std.testing.expectEqual(twice[0].capability.raw(), twice[1].capability.raw());
    try f.host.releaseCapability(twice[0].capability, 2);
    try std.testing.expect(!third.state().holdsImport(.from(7)));
}

test "a redeemed route lifts once under every custody and yields the import's one identity" {
    var f: Fixture = undefined;
    try f.init(0xAC, "127.0.0.1:9895");
    defer f.deinit();
    var third: Exporter = undefined;
    try third.init(0xE2, "127.0.0.1:9915", &f);
    defer third.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The first lift's handle is kept, so every later route finds the identity
    // already held and shares it. Each route is observed twice in one batch:
    // the first observation consumes it and the second finds it gone.
    try third.pair.a.served.port.peer.importObject(7);
    try third.pair.a.served.port.peer.importObject(7);
    try third.pair.a.served.port.peer.importObject(7);
    const first = try third.route(&f, 71);
    const held = try f.lift(arena, &.{first}, .borrowed);
    try std.testing.expect(f.host.node.redeemedRouteId(first.reference) == null);
    inline for (.{ .borrowed, .partner, .queued }, .{ 72, 73, 74 }) |input, answer| {
        const route = try third.route(&f, answer);
        try std.testing.expect(f.host.node.redeemedRouteId(route.reference) != null);
        const lifted = try f.lift(arena, &.{ route, route }, input);
        try std.testing.expect(f.host.node.redeemedRouteId(route.reference) == null);
        try std.testing.expectEqual(held[0].capability.raw(), lifted[0].capability.raw());
        try std.testing.expectEqual(held[0].capability.raw(), lifted[1].capability.raw());
        try f.host.releaseCapability(lifted[0].capability, 1);
        try f.host.releaseCapability(lifted[1].capability, 1);
    }
    try f.host.releaseCapability(held[0].capability, 1);
    try std.testing.expect(!third.state().holdsImport(.from(7)));
}

test "an inline give is refused before the Node sees it for a borrowed tree and accepted for a consumed one" {
    var f: Fixture = undefined;
    try f.init(0xAE, "127.0.0.1:9897");
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var handoff: model.Handoff = .{ .give = inlineGive() };
    const arg: model.Argument = .{ .handoff = &handoff };

    try f.peer().importObject(7);
    const before = f.snapshot(7);
    try std.testing.expectError(error.UnsupportedValue, f.lift(arena, &.{ far7, arg }, .borrowed));
    try std.testing.expectEqual(before, f.snapshot(7));
    try std.testing.expect(f.host.pending_inline_gives.get(f.session.peer_handle) == null);
    try std.testing.expect(f.host.node.nextAction() == null);

    var pending: u32 = 0;
    inline for (.{ .partner, .queued }) |input| {
        const accepted = try f.lift(arena, &.{arg}, input);
        pending += 1;
        try std.testing.expectEqual(@as(?u32, pending), f.host.pending_inline_gives.get(f.session.peer_handle));
        try f.host.releaseCapability(accepted[0].capability, 1);
    }
}

fn expectConsumedRetirement(seed: u8, designator: []const u8, input: lift_input, expected: anyerror) !void {
    var f: Fixture = undefined;
    try f.init(seed, designator);
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = try chain(arena);

    try f.peer().importObject(7);
    const refusal = switch (input) {
        .partner => f.lift(arena, &.{ far7, deep }, .partner),
        .queued => f.lift(arena, &.{ far7, deep }, .queued),
    };
    try std.testing.expectError(expected, refusal);
    // The consumed observation was released on the wire and its import retired.
    try std.testing.expect(!f.state().holdsImport(.from(7)));
    try std.testing.expectEqual(@as(?u64, null), f.state().hostCapabilityFor(.from(7)));
    try std.testing.expect(f.peer().hasOutbound());
}

const lift_input = enum { partner, queued };

test "the hosting adapter lifts a near call's arguments as borrowed and a queued call's as queued" {
    var f: Fixture = undefined;
    try f.init(0xB8, "127.0.0.1:9902");
    defer f.deinit();
    Probe.ran = 0;
    const exported = try f.session.served.publish(&f.host.vat, "probe", driver.core.Hosting(Probe), .{ .inner = .{} });
    var handoff: model.Handoff = .{ .give = inlineGive() };
    const args = [_]model.Argument{ far7, .{ .handoff = &handoff } };

    // A near call is the caller's value: the give is refused at the adapter's
    // own lift, the behavior never runs, and the import is exactly as it was.
    try f.peer().importObject(7);
    const before = f.snapshot(7);
    try std.testing.expectError(error.UnsupportedValue, f.host.vat.nearFromPort(&f.session.served.port, exported.ref, .{ .verb = "go", .args = &args }));
    try std.testing.expectEqual(@as(usize, 0), Probe.ran);
    try f.expectKept(before, 7);
    try std.testing.expect(f.host.pending_inline_gives.get(f.session.peer_handle) == null);
    try std.testing.expect(f.host.node.nextAction() == null);

    // A queued message was consumed from its sender, so the same give is accepted.
    _ = try f.session.served.port.send(&f.host.vat, exported.ref, .{ .verb = "go", .args = &args });
    _ = try f.host.vat.driveIngressBudgeted(f.session.served.port.ingress, 4);
    try std.testing.expectEqual(@as(usize, 1), Probe.ran);
    try std.testing.expectEqual(@as(?u32, 1), f.host.pending_inline_gives.get(f.session.peer_handle));
}

test "a consumed partner tree past the ceiling retires every reference through wire GC" {
    try expectConsumedRetirement(0xB0, "127.0.0.1:9898", .partner, error.NestingTooDeep);
}

test "a consumed queued tree past the ceiling retires every reference through wire GC" {
    try expectConsumedRetirement(0xB2, "127.0.0.1:9899", .queued, error.ValueTooDeep);
}
