//! A borrowed lift of a promise-shaped value (a settled or pending answer, a
//! local promise projection, a forwarded near reply) leaves the same ownership
//! the plain lifts do: only its own claims undone, the session serving.

const std = @import("std");
const glowcap = @import("glowcap");
const shapes = @import("../../support/depth_shapes.zig");
const test_host = @import("../../support/core_host.zig");
const host_pair = @import("../../support/host_pair.zig");
const capture = @import("../../support/capture.zig");
const fixture = @import("borrowed_lift_fixture.zig");

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

/// A raw Vat actor whose reply names an import the session holds and one it
/// does not, so the reply lift refuses after claiming the first.
const ReplyNamingUnheld = struct {
    var ran: u32 = 0;
    const items = [_]model.Argument{ far7, .{ .reference = .{ .far = model.FarRef.object(99) } } };
    pub fn handle(_: *ReplyNamingUnheld, _: *actors.Turn, _: actors.Delivery) !model.Argument {
        ran += 1;
        return .{ .list = &items };
    }
};

/// Forwards its call to a target and lifts that target's reply for its caller.
const Hop = struct {
    var ran: u32 = 0;
    target: driver.Capability,
    pub fn handle(self: *Hop, turn: *driver.HostTurn, verb: ?[]const u8, args: driver.Args) !driver.Value {
        defer turn.releaseArguments(args);
        ran += 1;
        return turn.forward(self.target, verb, try args.values());
    }
};

test "a forwarded near reply is lifted as borrowed and its refusal leaves the callee's reply alone" {
    var f: Fixture = undefined;
    try f.init(0xBC, "127.0.0.1:9904");
    defer f.deinit();
    Hop.ran = 0;
    ReplyNamingUnheld.ran = 0;

    const reservation = try f.host.reserveFreshCapability(null);
    const actor = try f.host.vat.spawn(ReplyNamingUnheld, .{});
    const raw = f.host.adoptReservedLocalCapability(reservation, actor);
    defer f.host.releaseCapabilityTerminal(raw, null);
    const hop = try f.session.served.publish(&f.host.vat, "hop", driver.core.Hosting(Hop), .{ .inner = .{ .target = raw } });

    try f.peer().importObject(7);
    const before = f.snapshot(7);
    // The reply names position 7 (held) and 99 (not held): the lift claims the
    // first, refuses the second, and the adapter's own undo returns the claim.
    // A consumed cleanup would GC-release 7 and condemn the session over 99.
    const result = f.host.vat.nearFromPort(&f.session.served.port, hop.ref, .{ .verb = "go" });
    // The reply lift refuses the unheld position inside Hop, so Hop's own
    // failure is the call's local error, after the callee ran.
    try std.testing.expectError(error.ForeignArgument, result);
    try std.testing.expectEqual(@as(u32, 1), Hop.ran);
    try std.testing.expectEqual(@as(u32, 1), ReplyNamingUnheld.ran);
    try f.expectKept(before, 7);
    try std.testing.expect(f.session.sessionOpen());

    // The next call refuses the same way: the session and the callee still serve.
    try std.testing.expectError(error.ForeignArgument, f.host.vat.nearFromPort(&f.session.served.port, hop.ref, .{ .verb = "go" }));
    try std.testing.expectEqual(@as(u32, 2), Hop.ran);
    try std.testing.expectEqual(@as(u32, 2), ReplyNamingUnheld.ran);
    try f.expectKept(before, 7);
}

/// Every allocation a borrowed lift of `[answer 7, over-deep]` makes, failed one
/// at a time after setup, until a run completes with no induced failure. Each
/// failure must leave the session, the import, the stored resolution's hold, and
/// the promise rows as they were, and the retry must still lift and release.
fn sweepRefusedAnswerLift(seed: u8, designator: []const u8, copies: usize, shared_import: bool) !usize {
    var n: usize = 0;
    while (n < 400) : (n += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = std.math.maxInt(usize) });
        var f: Fixture = undefined;
        try f.initIn(failing.allocator(), seed, designator);
        defer f.deinit();
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const deep = try chain(arena);
        // The lift's own arena draws from the failing allocator too, so the
        // receipt spill that lives in it is part of the sweep.
        var lift_arena_state = std.heap.ArenaAllocator.init(failing.allocator());
        defer lift_arena_state.deinit();
        const lift_arena = lift_arena_state.allocator();
        const position = try settleAnswerNamingPartnerObject(&f, arena, copies);
        const pos: model.ImportPosition = .from(position);
        const imports = &f.state().imports;
        const holds = imports.resolutionHolds(pos);
        const held_back = imports.rows.get(position).?.held_back;
        const before = f.snapshot(position);
        const answers_before = f.state().inbound_answers.host_promises;
        const answer: model.Argument = .{ .reference = .{ .promise = .{ .answer_position = .from(7) } } };
        // The outer tree names the import the answer's data names too.
        const same: model.Argument = .{ .reference = .{ .far = model.FarRef.object(position) } };
        const tree = [_]model.Argument{ same, answer, deep };
        const args = if (shared_import) tree[0..] else tree[1..];

        failing.fail_index = failing.alloc_index + n;
        const result = f.lift(lift_arena, args, .borrowed);
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        if (induced) try std.testing.expectError(error.OutOfMemory, result) else {
            try std.testing.expectError(error.ValueTooDeep, result);
        }
        try f.expectKept(before, position);
        try std.testing.expectEqual(holds, imports.resolutionHolds(pos));
        try std.testing.expectEqual(held_back, imports.rows.get(position).?.held_back);
        try std.testing.expectEqual(answers_before, f.state().inbound_answers.host_promises);

        const retry = try f.lift(lift_arena, args[0 .. args.len - 1], .borrowed);
        try std.testing.expectEqual(@as(u64, 0), imports.rows.get(position).?.held_back);
        for (retry) |lifted| switch (lifted) {
            .capability => |ref| try f.host.releaseCapability(ref, 1),
            else => unreachable,
        };
        try host_pair.pumpToQuiescence(&.{f.pair});
        try std.testing.expectEqual(before, f.snapshot(position));
        try std.testing.expectEqual(holds, imports.resolutionHolds(pos));
        if (!induced) return n;
    }
    return error.SweepNeverCompleted;
}

test "a borrowed lift of a settled answer survives an allocation refusal at every step" {
    // The sweep reaches the data's arena, the receipt spill, the row, and the
    // undo, which the earlier design broke at its first three failures.
    try std.testing.expect(try sweepRefusedAnswerLift(0xC0, "127.0.0.1:9906", 1, false) >= 4);
}

test "a refused borrowed answer lift whose data outgrows the inline receipts undoes every claim" {
    // Nine references in the data, past the eight inline receipts.
    try std.testing.expect(try sweepRefusedAnswerLift(0xC4, "127.0.0.1:9908", 9, false) > try sweepRefusedAnswerLift(0xC3, "127.0.0.1:9907", 1, false));
}

test "an outer reference to the same import as the answer's data unwinds exactly" {
    try std.testing.expect(try sweepRefusedAnswerLift(0xC5, "127.0.0.1:9909", 2, true) >= 4);
}

test "a borrowed lift of a local promise projection, then a refusal, leaves its subscription with the session" {
    var f: Fixture = undefined;
    try f.init(0xBE, "127.0.0.1:9905");
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = try chain(arena);

    // The session's own projection owner mints the local promise a `.near`
    // promise reference names.
    const projection = try f.state().allocateLocalPromiseProjection();
    f.state().exports.retain(projection.export_position);
    const promise: model.Argument = .{ .reference = .{ .near = .{ .export_position = projection.export_position, .kind = .promise } } };
    const rows_before = f.host.capability_promises.count();
    const subscribed_before = f.state().inbound_answers.host_promises;
    const live_before = f.host.capabilities.liveCount();

    try std.testing.expectError(error.ValueTooDeep, f.lift(arena, &.{ promise, deep }, .borrowed));
    try std.testing.expectEqual(rows_before, f.host.capability_promises.count());
    try std.testing.expectEqual(subscribed_before, f.state().inbound_answers.host_promises);
    try std.testing.expectEqual(live_before, f.host.capabilities.liveCount());
    try std.testing.expect(!f.peer().hasOutbound());
    try std.testing.expect(f.peer().lastAbort() == null);
    try std.testing.expectEqual(HostSession.LifecyclePhase.active, f.session.lifecyclePhase());

    // The retry subscribes once, and the release gives the subscription back.
    const retry = try f.lift(arena, &.{promise}, .borrowed);
    try std.testing.expectEqual(rows_before + 1, f.host.capability_promises.count());
    try std.testing.expectEqual(subscribed_before + 1, f.state().inbound_answers.host_promises);
    try f.host.releaseCapability(retry[0].capability, 1);
    try std.testing.expectEqual(rows_before, f.host.capability_promises.count());
    try std.testing.expectEqual(subscribed_before, f.state().inbound_answers.host_promises);
    try std.testing.expectEqual(live_before, f.host.capabilities.liveCount());
}

test "a refused borrowed lift of a local actor leaves its root balance to the original owner" {
    var f: Fixture = undefined;
    try f.init(0xBA, "127.0.0.1:9903");
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = try chain(arena);

    for ([_]bool{ false, true }) |retried| {
        const exported = try f.session.served.publish(&f.host.vat, "local", LocalActor, .{});
        const id = exported.ref.local;
        const near: model.Argument = exported.arg();
        try std.testing.expectError(error.ValueTooDeep, f.lift(arena, &.{ near, deep }, .borrowed));
        if (retried) {
            // The retry's handle holds its own root, so the original owner's
            // release alone does not retire the actor, and the handle's does.
            const handle = try f.lift(arena, &.{near}, .borrowed);
            f.host.vat.releaseActor(id);
            try std.testing.expect(f.host.vat.hasActor(id));
            try f.host.releaseCapability(handle[0].capability, 1);
        } else {
            // Nothing the refused lift took remains, so the original owner's
            // release retires the actor.
            f.host.vat.releaseActor(id);
        }
        try std.testing.expect(!f.host.vat.hasActor(id));
    }
}

test "a borrowed lift of a pending answer, then a refusal, leaves no lifted answer" {
    var f: Fixture = undefined;
    try f.init(0xAC, "127.0.0.1:9896");
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = try chain(arena);

    // The partner's open question at answer 7 reaches this Host's session.
    _ = try f.session.served.publish(&f.host.vat, "greeter", driver.core.Hosting(Greeter), .{ .inner = .{} });
    const greeter = try partnerImport(&f, "greeter");
    try f.pair.b.served.port.peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(greeter) },
        .args = &.{.{ .symbol = "greet" }},
        .answer = .from(7),
    } });
    try f.pair.b.served.port.peer.stepToIdle();
    try host_pair.shuttleUntilQuiet(&.{f.pair});
    try std.testing.expect(f.peer().lastAbort() == null);

    const answer: model.Argument = .{ .reference = .{ .promise = .{ .answer_position = .from(7) } } };
    const lifted_before = f.state().inbound_answers.host_promises;
    const rows_before = f.host.capability_promises.count();
    try std.testing.expectError(error.ValueTooDeep, f.lift(arena, &.{ answer, deep }, .borrowed));
    try std.testing.expectEqual(lifted_before, f.state().inbound_answers.host_promises);
    try std.testing.expectEqual(rows_before, f.host.capability_promises.count());
    try std.testing.expectEqual(HostSession.LifecyclePhase.active, f.session.lifecyclePhase());

    const retry = try f.lift(arena, &.{answer}, .borrowed);
    try std.testing.expectEqual(lifted_before + 1, f.state().inbound_answers.host_promises);
    try f.host.releaseCapability(retry[0].capability, 1);
}

/// Serves a reference-free object the partner can name.
const Target = struct {
    pub fn handle(_: *@This(), _: *driver.HostTurn, _: ?[]const u8, _: driver.Args) !driver.Value {
        return .{ .void = {} };
    }
};

/// Settle the partner's question 7 with data naming a partner object, then let
/// go of this Host's own handle, so the stored resolution alone holds the
/// import. Returns the import's position.
fn settleAnswerNamingPartnerObject(f: *Fixture, arena: std.mem.Allocator, copies: usize) !u64 {
    _ = try f.session.served.publish(&f.host.vat, "greeter", driver.core.Hosting(Greeter), .{ .inner = .{} });
    const greeter = try partnerImport(f, "greeter");
    _ = try f.pair.b.served.publish(&f.partner.vat, "target", driver.core.Hosting(Target), .{ .inner = .{} });
    const position = try importOf(&f.host, f.session, f.pair, "target");
    const target = try f.host.liftCapability(f.session, .{ .far = model.FarRef.object(position) });

    try f.pair.b.served.port.peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(greeter) },
        .args = &.{.{ .symbol = "greet" }},
        .answer = .from(7),
    } });
    try f.pair.b.served.port.peer.stepToIdle();
    try host_pair.shuttleUntilQuiet(&.{f.pair});
    // The settled data names the partner's object, then the application lets go
    // of its own handle, so the stored resolution alone holds the import.
    var entries: [2]driver.Value.StructEntry = .{
        .{ .key = "owner", .value = .{ .capability = target } },
        .{ .key = "count", .value = .{ .string = "three" } },
    };
    // One copy is a struct. More name the same object in a list, so the data's
    // receipts outgrow the transaction's inline capacity.
    const items = try arena.alloc(driver.Value, copies);
    for (items) |*item| item.* = .{ .capability = target };
    const settled: driver.Value = if (copies == 1) .{ .@"struct" = &entries } else .{ .list = items };
    try f.host.resolverFulfillValue(Greeter.resolver, settled, arena);
    try host_pair.pumpToQuiescence(&.{f.pair});
    try f.host.releaseCapability(target, 1);
    try host_pair.pumpToQuiescence(&.{f.pair});

    return position;
}

test "a borrowed lift of a settled answer returns the holds its data claimed" {
    var f: Fixture = undefined;
    try f.init(0xB6, "127.0.0.1:9901");
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = try chain(arena);

    const position = try settleAnswerNamingPartnerObject(&f, arena, 1);
    const pos: model.ImportPosition = .from(position);
    const imports = &f.state().imports;
    try std.testing.expectEqual(@as(u64, 1), imports.resolutionHolds(pos));
    try std.testing.expectEqual(@as(u64, 1), imports.rows.get(position).?.held_back);
    const before = f.snapshot(position);
    const answers_before = f.state().inbound_answers.host_promises;

    const answer: model.Argument = .{ .reference = .{ .promise = .{ .answer_position = .from(7) } } };
    try std.testing.expectError(error.ValueTooDeep, f.lift(arena, &.{ answer, deep }, .borrowed));
    try f.expectKept(before, position);
    try std.testing.expectEqual(@as(u64, 1), imports.resolutionHolds(pos));
    try std.testing.expectEqual(@as(u64, 1), imports.rows.get(position).?.held_back);
    try std.testing.expectEqual(answers_before, f.state().inbound_answers.host_promises);

    // The caller retries with the answer, and its release gives the same state back.
    const retry = try f.lift(arena, &.{answer}, .borrowed);
    // The lift owned the data, so it took the parked retain: the path ran.
    try std.testing.expectEqual(@as(u64, 0), imports.rows.get(position).?.held_back);
    try f.host.releaseCapability(retry[0].capability, 1);
    try host_pair.pumpToQuiescence(&.{f.pair});
    try std.testing.expectEqual(before, f.snapshot(position));
    try std.testing.expectEqual(@as(u64, 1), imports.resolutionHolds(pos));
}

/// A raw Peer on the Host's own session answers question 7 with a signed inline
/// give, the one way a stored resolution holds a handoff. The Host application
/// cannot author one, so this goes below it, through `Peer.sendResolveHandoffGive`.
fn settleAnswerWithGive(f: *Fixture, with_leading_ref: bool) !u64 {
    const engine = glowcap.ocapn.engine;
    const crypto = glowcap.foundation.crypto;
    _ = try f.session.served.publish(&f.host.vat, "greeter", driver.core.Hosting(Greeter), .{ .inner = .{} });
    const greeter = try partnerImport(f, "greeter");
    _ = try f.pair.b.served.publish(&f.partner.vat, "target", driver.core.Hosting(Target), .{ .inner = .{} });
    const position = try importOf(&f.host, f.session, f.pair, "target");
    try f.pair.b.served.port.peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(greeter) },
        .args = &.{.{ .symbol = "greet" }},
        .answer = .from(7),
    } });
    try f.pair.b.served.port.peer.stepToIdle();
    try host_pair.shuttleUntilQuiet(&.{f.pair});

    const gifter_secret = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(7)));
    const peer = f.session.served.port.peer;
    // An outbound give names the partner it is sent to.
    const recipient_key = peer.session_state.partnerSessionKey() orelse return error.NoPartnerKey;
    const exporter_key = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(8))).publicKey().asBytes();
    const location = try engine.encodePeerLocatorRecord(allocator, .{
        .transport = "tcp",
        .designator = "127.0.0.1:9070",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(location);
    const gifter_side = try engine.handoff_names.sideName(gifter_secret.publicKey().asBytes());
    const exporter_side = try engine.handoff_names.sideName(exporter_key);
    const session_name = engine.handoff_names.sessionName(gifter_side, exporter_side);
    const gift_id = @as([32]u8, @splat(0x5a));
    const give = try engine.handoff_gifter.buildSignedGive(allocator, gifter_secret, recipient_key, location, &session_name, &gifter_side, &gift_id);
    defer allocator.free(give);
    if (with_leading_ref) {
        // A reference the lift claims, then the give it refuses.
        const handoff = try engine.handoff_gifter.decodeHandoffGive(allocator, give);
        defer model.freeArgument(allocator, .{ .handoff = handoff });
        const items = [_]model.Argument{
            .{ .reference = .{ .far = model.FarRef.object(position) } },
            .{ .handoff = handoff },
        };
        try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(7), .resolution = .{ .fulfill = .{ .list = &items } } } });
    } else {
        try peer.sendResolveHandoffGive(peer.session_state.answerTargetNamed(.fromWire(.from(7))).?, give);
    }
    // The partner has an introduction to redeem, so the pair never rests.
    try host_pair.shuttleUntilQuiet(&.{f.pair});
    return position;
}

test "settled data holding an inline give lifts as a broken promise when borrowed, with no claim left" {
    // Both layouts: the give alone, and a reference the lift claims before the
    // give it refuses, which the broken row's undo must return.
    inline for (.{ false, true }, .{ "127.0.0.1:9911", "127.0.0.1:9912" }) |leading, designator| {
        var f: Fixture = undefined;
        try f.init(if (leading) 0xC9 else 0xC8, designator);
        defer f.deinit();
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const deep = try chain(arena);
        const position = try settleAnswerWithGive(&f, leading);
        const before = f.snapshot(position);
        const answer: model.Argument = .{ .reference = .{ .promise = .{ .answer_position = .from(7) } } };

        // The give is refused before the Node sees it, so the row is broken, the
        // later outer refusal retires it, and nothing is left.
        try std.testing.expectError(error.ValueTooDeep, f.lift(arena, &.{ answer, deep }, .borrowed));
        try f.expectKept(before, position);
        try std.testing.expect(f.host.pending_inline_gives.get(f.session.peer_handle) == null);

        // An outer lift that commits keeps the broken promise, and its release retires it.
        const kept = try f.lift(arena, &.{answer}, .borrowed);
        try std.testing.expect(f.host.pending_inline_gives.get(f.session.peer_handle) == null);
        try std.testing.expectEqual(before.promises + 1, f.snapshot(position).promises);
        // The kept row is the broken promise, broken by the refused give.
        const promise = f.host.capabilities.resolve(kept[0].capability).?.deferred;
        const row = f.host.capability_promises.getPtr(promise).?;
        try std.testing.expectEqualStrings(@errorName(error.UnsupportedValue), row.state.broken.message());
        try std.testing.expectEqual(before.lifted, f.snapshot(position).lifted);
        try f.host.releaseCapability(kept[0].capability, 1);
        try std.testing.expectEqual(before.promises, f.snapshot(position).promises);
    }
}
