//! A vow passed outbound as a capability (ADR-0068). An application asks a
//! question and passes the pending answer along before it settles. On the
//! question's own session the argument is the open answer, and the partner
//! treats it as the promise it already holds. On another session it is a
//! promise this Host projects and settles. Each holder sees one settlement:
//! data, a capability, or a break. The promise outlives a released vow
//! handle, leaves with its last retain, and breaks with its session.
const std = @import("std");
const glowcap = @import("glowcap");
const driver = glowcap.driver;
const capture = @import("../support/capture.zig");
const harness = @import("core_host/harness.zig");
const trio = @import("vow_capability/trio.zig");
const Trio = trio.Trio;
const ReaderA = trio.ReaderA;
const ReaderB = trio.ReaderB;
const ReaderC = trio.ReaderC;
const GreeterA = trio.GreeterA;
const GreeterB = trio.GreeterB;
const Keeper = trio.Keeper;
const Target = trio.Target;
const listenOn = trio.listenOn;

test "a pending vow passed on its own session and to a third peer settles once with the data on each" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();

    const vow = try t.ask();
    const cap = try t.a.vowCapability(vow);
    try t.expectState(cap, .pending);

    // On the greeter's own session the argument is a promise `a` projects,
    // never the open answer: that position is `a`'s question, and `b` would
    // read it as one of its own.
    try t.passToB(cap);
    try std.testing.expectEqual(@as(usize, 1), ReaderB.ran);
    try std.testing.expect(ReaderB.promise_id == null);
    try std.testing.expectEqual(@as(u32, 0), t.liftedAnswersAtB());
    var b_listened: capture.CapturedString = .{};
    try listenOn(&t.b, ReaderB.listen_vow, &b_listened);
    var b_sent: capture.CapturedString = .{};
    try listenOn(&t.b, ReaderB.send_vow, &b_sent);

    // On the other session it is a promise `a` projects.
    try t.passToC(cap);
    try std.testing.expectEqual(@as(usize, 1), ReaderC.ran);
    try std.testing.expect(ReaderC.promise_id == null);
    var c_listened: capture.CapturedString = .{};
    try listenOn(&t.c, ReaderC.listen_vow, &c_listened);
    var c_sent: capture.CapturedString = .{};
    try listenOn(&t.c, ReaderC.send_vow, &c_sent);

    try t.fulfill("hello");
    try std.testing.expectEqualStrings("hello", b_listened.text());
    try std.testing.expect(b_sent.broken);
    try std.testing.expectEqualStrings("hello", c_listened.text());
    try std.testing.expect(c_sent.broken);
    try t.expectState(cap, .fulfilled_data);
    try std.testing.expectEqual(@as(usize, 0), t.a.node.actions.promise_settlements);

    try t.a.releaseCapability(cap, 1);
    try t.expectClean();
}

test "a vow that settles with a capability fulfills the promise to it" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();
    const target = try t.b.spawn(t.ab.b, driver.core.Hosting(Target), .{ .inner = .{} });
    defer t.b.releaseCapabilityTerminal(target, null);

    const vow = try t.ask();
    const cap = try t.a.vowCapability(vow);
    try t.passToB(cap);
    var b_sent: capture.CapturedString = .{};
    try listenOn(&t.b, ReaderB.send_vow, &b_sent);
    try t.passToC(cap);
    var c_sent: capture.CapturedString = .{};
    try listenOn(&t.c, ReaderC.send_vow, &c_sent);
    var c_seen: capture.CapturedRef = .{};
    try t.c.vowOn(ReaderC.listen_vow, .{ .ctx = &c_seen, .func = capture.CapturedRef.record });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try t.b.resolverFulfillValue(GreeterB.resolver, .{ .capability = target }, arena.allocator());
    try t.pump();
    try std.testing.expectEqualStrings("from the target", b_sent.text());
    try t.expectState(cap, .fulfilled);

    // Toward `c` the settlement is a handoff to `b`, which `c` redeems over
    // its own session to `b`. The call `c` pipelined onto the promise sits
    // on `a`, which cannot carry it to another session, so it breaks.
    try t.redeemAtB();
    const c_target = try t.c.liftCapability(t.pair_buf[2].a, c_seen.ref orelse return error.HandoffUnsettled);
    try std.testing.expect((try t.c.capabilitySession(c_target)) == t.pair_buf[2].a);
    try std.testing.expect(c_sent.broken);
    const c_hit = try t.c.sendValues(t.pair_buf[2].a, c_target, "hit", &.{}, t.arena.allocator());
    var c_heard: capture.CapturedString = .{};
    try listenOn(&t.c, c_hit, &c_heard);
    try t.pump();
    try std.testing.expectEqualStrings("from the target", c_heard.text());
    try t.c.releaseCapability(c_target, 1);

    // The promise is the target to `a` as well.
    const hit = try t.a.sendValues(t.ab.a, cap, "hit", &.{}, t.arena.allocator());
    var a_heard: capture.CapturedString = .{};
    try listenOn(&t.a, hit, &a_heard);
    try t.pump();
    try std.testing.expectEqualStrings("from the target", a_heard.text());
    try std.testing.expectEqual(@as(usize, 3), Target.ran);

    try t.a.releaseCapability(cap, 1);
    try t.expectClean();
}

test "a vow that breaks breaks the promise on both peers" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();

    const vow = try t.ask();
    const cap = try t.a.vowCapability(vow);
    try t.passToB(cap);
    var b_listened: capture.CapturedString = .{};
    try listenOn(&t.b, ReaderB.listen_vow, &b_listened);
    try t.passToC(cap);
    var c_listened: capture.CapturedString = .{};
    try listenOn(&t.c, ReaderC.listen_vow, &c_listened);

    try t.b.resolverBreak(GreeterB.resolver, "no greeting");
    try t.pump();
    try std.testing.expect(b_listened.broken);
    try std.testing.expect(c_listened.broken);
    try t.expectState(cap, .broken);

    try t.a.releaseCapability(cap, 1);
    try t.expectClean();
}

test "the same vow asked twice is one promise, and the vow still completes on its own" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();

    const vow = try t.ask();
    const first = try t.a.vowCapability(vow);
    const second = try t.a.vowCapability(vow);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), t.a.capability_promises.count());

    // Letting both retains go before the settlement leaves nothing waiting:
    // the row and its seat go at once, and the vow is untouched.
    try t.a.releaseCapability(first, 2);
    try std.testing.expectEqual(@as(usize, 0), t.a.capability_promises.count());
    try std.testing.expectEqual(@as(usize, 0), t.a.node.actions.promise_settlements);
    var heard: capture.CapturedString = .{};
    try listenOn(&t.a, vow, &heard);
    try t.fulfill("hello");
    try std.testing.expectEqualStrings("hello", heard.text());
    try t.expectClean();
}

test "a released vow handle lives for its promise and leaves with the settlement" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();

    const vow = try t.ask();
    const cap = try t.a.vowCapability(vow);
    try t.passToC(cap);
    var c_listened: capture.CapturedString = .{};
    try listenOn(&t.c, ReaderC.listen_vow, &c_listened);

    try t.a.vowRelease(vow);
    try std.testing.expectError(error.NoSuchVow, t.a.vowOn(vow, .{ .ctx = &c_listened, .func = capture.CapturedString.record }));
    try std.testing.expectError(error.NoSuchVow, t.a.vowCapability(vow));
    try std.testing.expectEqual(@as(usize, 1), t.a.vows.count());

    try t.fulfill("hello");
    try std.testing.expectEqualStrings("hello", c_listened.text());
    try std.testing.expectEqual(@as(usize, 0), t.a.vows.count());
    try std.testing.expectEqual(@as(usize, 0), t.a.pendingVowCount());
    try t.expectState(cap, .fulfilled_data);

    try t.a.releaseCapability(cap, 1);
    try t.expectClean();
}

test "a settled vow passes as a promise that settles to the completion its row kept" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();

    const vow = try t.ask();
    try t.fulfill("hello");
    try std.testing.expect(t.a.vows.get(vow).?.completion == .fulfilled);
    const cap = try t.a.vowCapability(vow);
    // On the vow's own session the promise projects as on any other, already
    // settled when it arrives, so `b`'s listen settles at once.
    ReaderB.keep = true;
    var b_listened: capture.CapturedString = .{};
    ReaderB.listen_into = &b_listened;
    try t.passToB(cap);
    try std.testing.expect(ReaderB.promise_id == null);
    try std.testing.expectEqualStrings("hello", b_listened.text());
    // Across sessions a promise settled to data is passed as that data.
    try t.passToC(cap);
    try std.testing.expectEqualStrings("hello", ReaderC.text());
    try t.expectState(cap, .fulfilled_data);

    try t.b.releaseCapability(ReaderB.kept.?, 1);
    try t.a.releaseCapability(cap, 1);
    try t.a.vowRelease(vow);
    try t.expectClean();
}

test "a vow asked for between its answer's arrival and its drain settles its promise from the drain" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();

    const vow = try t.ask();
    try t.b.resolverFulfill(GreeterB.resolver, .{ .string = "hello" });
    // Carry the answer to `a` without draining its actions: the row is
    // settled and its completion is still queued.
    var rounds: usize = 0;
    while (try harness.shuttleAll(t.pairs())) : (rounds += 1) {
        if (rounds == 16) return error.ShuttleDidNotSettle;
    }
    const row = t.a.vows.get(vow).?;
    try std.testing.expect(row.settled and row.completion == .none);
    const cap = try t.a.vowCapability(vow);
    try t.expectState(cap, .pending);

    var c_listened: capture.CapturedString = .{};
    ReaderC.listen_into = &c_listened;
    try t.passToC(cap);
    try std.testing.expectEqualStrings("hello", c_listened.text());
    try t.expectState(cap, .fulfilled_data);

    try t.a.releaseCapability(cap, 1);
    try t.a.vowRelease(vow);
    try t.expectClean();
}

test "a vow released while its promise waits on the drain still settles the promise" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();

    const vow = try t.ask();
    try t.b.resolverFulfill(GreeterB.resolver, .{ .string = "hello" });
    var rounds: usize = 0;
    while (try harness.shuttleAll(t.pairs())) : (rounds += 1) {
        if (rounds == 16) return error.ShuttleDidNotSettle;
    }
    const cap = try t.a.vowCapability(vow);
    try t.a.vowRelease(vow);
    try std.testing.expectError(error.NoSuchVow, t.a.vowCapability(vow));

    // On `b`'s session the promise travels as a projection and settles there.
    var b_listened: capture.CapturedString = .{};
    ReaderB.listen_into = &b_listened;
    try t.passToB(cap);
    try std.testing.expectEqualStrings("hello", b_listened.text());
    // That pass drained the completion, which staged and settled the
    // promise, so toward `c` it is its data.
    try t.passToC(cap);
    try std.testing.expectEqualStrings("hello", ReaderC.text());
    try t.expectState(cap, .fulfilled_data);
    try std.testing.expect(t.a.vows.get(vow) == null);

    try t.a.releaseCapability(cap, 1);
    try t.expectClean();
}

test "a vow that broke before it was asked for passes as a promise that breaks with its reason" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();

    const vow = try t.ask();
    try t.b.resolverBreak(GreeterB.resolver, "no greeting");
    try t.pump();
    try std.testing.expect(t.a.vows.get(vow).?.completion == .failed);
    const cap = try t.a.vowCapability(vow);
    // The break is staged and the pump has not run it, so the pass projects a
    // breaking promise.
    try t.expectState(cap, .breaking);
    var c_listened: capture.CapturedRef = .{};
    ReaderC.listen_into_ref = &c_listened;
    try t.passToC(cap);
    try std.testing.expectEqual(@as(usize, 1), ReaderC.ran);
    try std.testing.expectEqualStrings("no greeting", c_listened.brokenReason());
    // The pass settled nothing at `a`: the row keeps its break.
    try t.expectState(cap, .broken);

    try t.a.releaseCapability(cap, 1);
    try t.a.vowRelease(vow);
    try t.expectClean();
}

test "a settled vow whose capability the application let go passes as a promise that breaks" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();
    const target = try t.b.spawn(t.ab.b, driver.core.Hosting(Target), .{ .inner = .{} });
    defer t.b.releaseCapabilityTerminal(target, null);

    const vow = try t.ask();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try t.b.resolverFulfillValue(GreeterB.resolver, .{ .capability = target }, arena.allocator());
    // The drain hands the capability to the application, which keeps no
    // retain of it here, so the row names a capability that is gone.
    try t.pump();
    const held = t.a.vows.get(vow).?.completion.fulfilled.value.capability;
    try std.testing.expect(t.a.capabilities.resolve(held) == null);
    const cap = try t.a.vowCapability(vow);
    try t.pump();
    try t.expectState(cap, .broken);
    var c_listened: capture.CapturedRef = .{};
    ReaderC.listen_into_ref = &c_listened;
    try t.passToC(cap);
    try std.testing.expectEqualStrings(@errorName(error.UnknownCapability), c_listened.brokenReason());

    try t.a.releaseCapability(cap, 1);
    try t.a.vowRelease(vow);
    try t.expectClean();
}

test "closing the vow's session breaks its promise toward a third peer" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();

    const vow = try t.ask();
    const cap = try t.a.vowCapability(vow);
    try t.passToC(cap);
    var c_listened: capture.CapturedString = .{};
    try listenOn(&t.c, ReaderC.listen_vow, &c_listened);

    try t.a.releaseSession(t.ab.a);
    try harness.pumpToQuiescence(std.testing.allocator, &t.hosts, &.{t.ac}, &t.dials);
    try std.testing.expect(c_listened.broken);
    try t.expectState(cap, .broken);
    try std.testing.expectEqual(@as(usize, 0), t.a.node.actions.promise_settlements);

    try t.a.releaseCapability(cap, 1);
    try std.testing.expectEqual(@as(usize, 0), t.a.capability_promises.count());
    try std.testing.expectEqual(@as(usize, 0), t.c.capability_promises.count());
}

test "a projected promise passed back is the promise it stands for" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();
    const echo = try t.fetchHeldOn(&t.c, t.ac.b, "echo");

    const vow = try t.ask();
    const cap = try t.a.vowCapability(vow);
    const promise_id = @backingInt(t.a.capabilities.resolve(cap).?.deferred);
    ReaderC.keep = true;
    try t.passToC(cap);
    const kept = ReaderC.kept orelse return error.NothingKept;

    // Before the settlement the projection coming back is the same promise.
    const echo_call = try t.c.sendValues(t.ac.b, echo, "read", &.{.{ .capability = kept }}, t.arena.allocator());
    var echo_heard: capture.CapturedRef = .{};
    try t.c.vowOn(echo_call, .{ .ctx = &echo_heard, .func = capture.CapturedRef.record });
    try t.pump();
    try std.testing.expect(!echo_heard.broken);
    try std.testing.expectEqual(@as(usize, 1), ReaderA.ran);
    try std.testing.expectEqual(promise_id, ReaderA.promise_id orelse return error.NoPromise);
    var a_listened: capture.CapturedString = .{};
    try listenOn(&t.a, ReaderA.listen_vow, &a_listened);

    try t.fulfill("hello");
    try std.testing.expectEqualStrings("hello", a_listened.text());

    // After it, the projection coming back is what the answer settled to.
    _ = try t.c.sendValues(t.ac.b, echo, "read", &.{.{ .capability = kept }}, t.arena.allocator());
    try t.pump();
    try std.testing.expectEqual(@as(usize, 2), ReaderA.ran);
    try std.testing.expect(ReaderA.promise_id != promise_id);
    try std.testing.expectEqual(@as(anyerror, error.UncallableTarget), ReaderA.send_refusal orelse return error.SendAccepted);

    try t.c.releaseCapability(kept, 1);
    try t.c.releaseCapability(echo, 1);
    try t.a.releaseCapability(cap, 1);
    try t.pump();
    try t.expectClean();
}

test "releasing a watched vow twice is one release" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();

    const vow = try t.ask();
    const cap = try t.a.vowCapability(vow);
    try t.passToC(cap);
    var c_listened: capture.CapturedString = .{};
    try listenOn(&t.c, ReaderC.listen_vow, &c_listened);

    // The first release reserves the answer's wire release for the fire.
    // The second finds a handle that is gone and reserves nothing more.
    try t.a.vowRelease(vow);
    const reserved = t.ab.a.served.port.peer.pending_send_reservations;
    try t.a.vowRelease(vow);
    try std.testing.expectEqual(reserved, t.ab.a.served.port.peer.pending_send_reservations);

    try t.fulfill("hello");
    try std.testing.expectEqualStrings("hello", c_listened.text());
    try std.testing.expectEqual(@as(usize, 0), t.a.vows.count());
    try std.testing.expectEqual(@as(usize, 0), t.ab.a.served.port.peer.pending_send_reservations);
    try t.a.releaseCapability(cap, 1);
    try t.expectClean();
}

test "a promise released after its vow handle lets the question go" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();

    const vow = try t.ask();
    const cap = try t.a.vowCapability(vow);
    try t.a.vowRelease(vow);
    try std.testing.expectEqual(@as(usize, 1), t.a.vows.count());

    // Nothing holds the question any more: no handle, no listener, and with
    // this release no promise. It goes at once instead of waiting on `b`.
    try t.a.releaseCapability(cap, 1);
    try std.testing.expectEqual(@as(usize, 0), t.a.vows.count());
    try std.testing.expectEqual(@as(usize, 0), t.a.pendingVowCount());
    try t.pump();
    try t.expectClean();
}

test "a vow fulfilled with the partner's pending question settles the promise to that question" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();

    // Six rows fill the promise table's first allocation, so lifting the
    // question adds a row through a grown table while the fire is staging.
    var fillers: [5]driver.Capability = undefined;
    for (&fillers) |*filler| {
        const asked = try t.a.sendValues(t.ab.a, t.greeter, "greet", &.{}, t.arena.allocator());
        filler.* = try t.a.vowCapability(asked);
    }
    const vow = try t.a.sendValues(t.ab.a, t.greeter, "greet", &.{}, t.arena.allocator());
    try t.pump();
    try std.testing.expectEqual(@as(usize, 6), GreeterB.ran);
    const cap = try t.a.vowCapability(vow);
    try t.passToC(cap);
    var c_listened: capture.CapturedString = .{};
    try listenOn(&t.c, ReaderC.listen_vow, &c_listened);

    // `b` asks `a`'s greeter and answers `a`'s question with that one.
    const greeter_a = try t.fetchHeldOn(&t.b, t.ab.b, "greeter");
    const question = try t.b.sendValues(t.ab.b, greeter_a, "greet", &.{}, t.arena.allocator());
    try t.pump();
    try std.testing.expectEqual(@as(usize, 1), GreeterA.ran);
    const question_cap = try t.b.vowCapability(question);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try t.b.resolverFulfillValue(GreeterB.resolver, .{ .capability = question_cap }, arena.allocator());
    try t.pump();
    try t.expectState(cap, .fulfilled);
    try std.testing.expectEqual(@as(usize, 6), t.a.capability_promises.count());
    try std.testing.expectEqualStrings("", c_listened.text());

    try t.a.resolverFulfill(GreeterA.resolver, .{ .string = "hello" });
    try t.pump();
    try std.testing.expectEqualStrings("hello", c_listened.text());

    for (fillers) |filler| try t.a.releaseCapability(filler, 1);
    try t.a.releaseCapability(cap, 1);
    // The row keeps the question it settled to until its handle goes.
    try t.a.vowRelease(vow);
    try t.b.releaseCapability(question_cap, 1);
    try t.b.vowRelease(question);
    try t.b.releaseCapability(greeter_a, 1);
    try t.pump();
    try t.expectClean();
}

test "a send queued on a pending promise is a vow that passes as a promise and settles with its reply" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();
    const target = try t.b.spawn(t.ab.b, driver.core.Hosting(Target), .{ .inner = .{} });
    defer t.b.releaseCapabilityTerminal(target, null);

    const vow = try t.ask();
    const cap = try t.a.vowCapability(vow);
    // Its promise reaches `b` as a projection.
    const hit = try t.a.sendValues(t.ab.a, cap, "hit", &.{}, t.arena.allocator());
    const hit_cap = try t.a.vowCapability(hit);
    try t.passToB(hit_cap);
    try std.testing.expect(ReaderB.promise_id == null);
    var b_listened: capture.CapturedString = .{};
    try listenOn(&t.b, ReaderB.listen_vow, &b_listened);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try t.b.resolverFulfillValue(GreeterB.resolver, .{ .capability = target }, arena.allocator());
    try t.pump();
    try std.testing.expectEqualStrings("from the target", b_listened.text());
    try t.expectState(hit_cap, .fulfilled_data);

    try t.a.releaseCapability(cap, 1);
    try t.a.releaseCapability(hit_cap, 1);
    try t.a.vowRelease(hit);
    try t.pump();
    try t.expectClean();
}

test "a vow answered with its own promise's projection breaks as a cycle" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();
    const keeper = try t.b.spawn(t.ab.b, driver.core.Hosting(Keeper), .{ .inner = .{} });
    defer t.b.releaseCapabilityTerminal(keeper, null);

    const vow = try t.ask();
    const cap = try t.a.vowCapability(vow);
    const hit = try t.a.sendValues(t.ab.a, cap, "hit", &.{}, t.arena.allocator());
    const hit_cap = try t.a.vowCapability(hit);
    ReaderB.keep = true;
    try t.passToB(hit_cap);
    const kept = ReaderB.kept orelse return error.NothingKept;
    var b_listened: capture.CapturedString = .{};
    try listenOn(&t.b, ReaderB.listen_vow, &b_listened);

    // The keeper answers `hit` with the projection of `hit`'s own promise.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try t.b.resolverFulfillValue(GreeterB.resolver, .{ .capability = keeper }, arena.allocator());
    try t.pump();
    try std.testing.expect(b_listened.broken);
    try t.expectState(hit_cap, .broken);

    try t.b.releaseCapability(kept, 1);
    try t.a.releaseCapability(cap, 1);
    try t.a.releaseCapability(hit_cap, 1);
    try t.a.vowRelease(hit);
    try t.pump();
    try t.expectClean();
}

test "a vow whose send moves sessions takes its promise to the session it settled through" {
    var t: Trio = undefined;
    try t.init();
    defer t.deinit();
    const greeter_again = try t.b.spawn(t.ab.b, driver.core.Hosting(GreeterB), .{ .inner = .{} });
    defer t.b.releaseCapabilityTerminal(greeter_again, null);

    const vow = try t.ask();
    const cap = try t.a.vowCapability(vow);
    // A send queued from the other session is owned there until the promise
    // settles, and its promise is made there too.
    const hit = try t.a.queueSendValues(t.ac.a, cap, "hit", &.{}, t.arena.allocator());
    const hit_cap = try t.a.vowCapability(hit);
    try t.passToC(hit_cap);

    // The promise settles to a greeter on `b`, so the send moves to that
    // session and parks on its own deferred answer there.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try t.b.resolverFulfillValue(GreeterB.resolver, .{ .capability = greeter_again }, arena.allocator());
    try t.pump();
    try std.testing.expectEqual(@as(usize, 2), GreeterB.ran);
    try t.expectState(cap, .fulfilled);
    try t.expectState(hit_cap, .pending);

    // The promise followed, and projects on `b`'s session as on any other.
    try t.passToB(hit_cap);
    try std.testing.expect(ReaderB.promise_id == null);
    try std.testing.expectEqual(@as(u32, 0), t.liftedAnswersAtB());
    var b_listened: capture.CapturedString = .{};
    try listenOn(&t.b, ReaderB.listen_vow, &b_listened);

    // Closing the session the send started on leaves it untouched.
    try t.a.releaseSession(t.ac.a);
    t.pair_len = 1;
    try t.pump();
    try t.expectState(hit_cap, .pending);

    try t.fulfill("done");
    try std.testing.expectEqualStrings("done", b_listened.text());
    try t.expectState(hit_cap, .fulfilled_data);

    try t.a.releaseCapability(cap, 1);
    try t.a.releaseCapability(hit_cap, 1);
    try t.a.vowRelease(hit);
    try t.pump();
    try t.expectClean();
}
