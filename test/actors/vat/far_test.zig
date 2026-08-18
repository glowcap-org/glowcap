//! The wire seam: far tells deliver with no answer, settled far vows refuse
//! a second resolve, breakFarVows settles everything broken including a vow
//! registered during the sweep, and listeners that re-enter serve still
//! read intact bytes off one converged resolve.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const promise_capture = @import("../../support/capture.zig");
const cross_peer = @import("../../support/cross_peer.zig");
const peer_fixture = @import("../../support/peer_fixture.zig");
const poison = @import("../../support/poison.zig");

const harness = @import("harness.zig");
const Counter = harness.Counter;
const Greeter = harness.Greeter;
const getN = harness.getN;
const Forwarder = harness.Forwarder;
const MutateThenRead = harness.MutateThenRead;
const Sink = harness.Sink;
const LabelHolder = harness.LabelHolder;
const PersistentCounter = harness.PersistentCounter;
const Captured = promise_capture.CapturedBytes;
const StringCapture = promise_capture.CapturedString;

test "far tell delivers with no answer and the partner replies nothing" {
    const allocator = std.testing.allocator;
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const host_peer = &pair.p1;
    const caller_peer = &pair.p2;

    var host_vat = actors.Vat.init(allocator);
    defer host_vat.deinit();
    var host_port = actors.Port.init(allocator, host_peer);
    defer host_port.deinit(&host_vat);
    const counter = try host_vat.spawn(Counter, .{ .n = 0 });
    try host_port.bindExport(&host_vat, counter, 5);
    try host_peer.exportObject(5);

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.init(allocator);
    defer caller_vat.deinit();
    var caller_port = actors.Port.init(allocator, caller_peer);
    defer caller_port.deinit(&caller_vat);

    // Fire-and-forget: no answer requested, so the caller holds no promise.
    try caller_port.tell(&caller_vat, .{ .far = model.FarRef.object(5) }, .{ .verb = "increment" });

    try cross_peer.pumpAll(caller_peer, host_peer);
    while (host_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = host_port.serve(&host_vat, &e) catch {};
    }

    // The actor ran on the host.
    try std.testing.expectEqual(@as(i64, 1), (try host_vat.near(counter, .{ .verb = "get" })).integer);
    // And the host produced no reply: an answer-less deliver settles nothing.
    _ = try host_peer.step();
    try std.testing.expect(host_peer.takeOutbound() == null);
}

test "on a far vow whose resolve already arrived is refused AlreadySettled" {
    const allocator = std.testing.allocator;
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const host_peer = &pair.p1;
    const caller_peer = &pair.p2;

    var host_vat = actors.Vat.init(allocator);
    defer host_vat.deinit();
    var host_port = actors.Port.init(allocator, host_peer);
    defer host_port.deinit(&host_vat);
    const counter = try host_vat.spawn(Counter, .{ .n = 0 });
    try host_port.bindExport(&host_vat, counter, 5);
    try host_peer.exportObject(5);

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.init(allocator);
    defer caller_vat.deinit();
    var caller_port = actors.Port.init(allocator, caller_peer);
    defer caller_port.deinit(&caller_vat);

    // A far send the host answers with the new count.
    const vow = try caller_port.send(&caller_vat, .{ .far = model.FarRef.object(5) }, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });

    // The deliver reaches the host, which runs the actor and resolves the answer.
    try cross_peer.pumpAll(caller_peer, host_peer);
    while (host_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = host_port.serve(&host_vat, &e) catch {};
    }
    // The host's resolve travels back to the caller and is applied.
    try cross_peer.pumpAll(host_peer, caller_peer);
    // The caller pumps the resolve *before* registering `on`: it fires with no
    // listener and is dropped, and the outbound answer is now settled.
    while (caller_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = caller_port.serve(&caller_vat, &e) catch {};
    }

    // A listener registered now would never fire, so it is refused loud —
    // the wire-side mirror of the local arm's settled guard.
    var captured = Captured{};
    try std.testing.expectError(
        actors.Error.AlreadySettled,
        caller_port.on(&caller_vat, vow, .{ .ctx = &captured, .func = Captured.record }),
    );
    // The refusal is idempotent: a retried `on` hits the same wall instead of
    // slipping past a consumed marker into a listener that can never fire.
    try std.testing.expectError(
        actors.Error.AlreadySettled,
        caller_port.on(&caller_vat, vow, .{ .ctx = &captured, .func = Captured.record }),
    );
}

test "breakFarVows settles outstanding far vows broken" {
    const allocator = std.testing.allocator;
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const caller_peer = &pair.p2;

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.init(allocator);
    defer caller_vat.deinit();
    var caller_port = actors.Port.init(allocator, caller_peer);
    defer caller_port.deinit(&caller_vat);

    // A far send the partner never answers: the vow stays pending until the
    // connection it rode on is gone.
    const vow = try caller_port.send(&caller_vat, .{ .far = model.FarRef.object(5) }, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });
    var broke = false;
    try caller_port.on(&caller_vat, vow, .{ .ctx = &broke, .func = promise_capture.captureBroken });

    // No resolution arrives; breaking the far vows fires the listener broken
    // rather than leaving the awaiter waiting on a reply that can never come.
    try std.testing.expect(!broke);
    caller_port.breakFarVows("connection closed");
    try std.testing.expect(broke);

    // Idempotent: a second break has nothing left to settle.
    caller_port.breakFarVows("connection closed");
}

test "bindExport refuses a far ref with NotLocal" {
    const allocator = std.testing.allocator;
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();

    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var port = actors.Port.init(allocator, &pair.p1);
    defer port.deinit(&vat);

    // Only a local actor can answer an export position this vat hosts; a far
    // ref already lives on the partner.
    try std.testing.expectError(
        actors.Error.NotLocal,
        port.bindExport(&vat, .{ .far = model.FarRef.object(3) }, 7),
    );
}

test "a listener that drives a state-mutating turn still reads an intact resolution" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const holder = try vat.spawn(LabelHolder, .{
        .allocator = allocator,
        .label = try allocator.dupe(u8, "before"),
    });

    // Turn one's reply borrows the actor's label; turn two frees that label
    // and installs a same-size replacement (which the allocator may hand back
    // the freed block for, scribbling the borrow). The settle clone is what
    // keeps the listener's read off the actor's mutable state.
    const promise = try vat.send(holder, .{ .verb = "get" });
    var capture = MutateThenRead{ .vat = &vat };
    try vat.on(promise, .{ .ctx = &capture, .func = MutateThenRead.record });
    try vat.tell(holder, .{ .verb = "relabel", .args = &.{.{ .bytes = "after!" }} });
    try vat.drive();

    try std.testing.expect(!capture.broke);
    try std.testing.expectEqualStrings("before", capture.buf[0..capture.len]);
}

/// Replies with a fresh turn-arena byte string naming the verb, for the
/// re-entrant far-settle test below.
const EchoVerb = struct {
    pub fn handle(self: *EchoVerb, turn: *Turn, msg: Message) !model.Argument {
        _ = self;
        return .{ .bytes = try std.fmt.allocPrint(turn.arena, "reply-{s}", .{msg.verb}) };
    }
};

/// A far listener that re-enters `serve` with a second resolve event while
/// its own resolution is live, then reads its bytes. The vat's settle-depth
/// guard is what keeps the nested settle from resetting the settle arena
/// under the outer value.
const NestedServeCapture = struct {
    vat: *actors.Vat,
    port: *actors.Port,
    inner_event: *pancake.ocapn.engine.Event,
    buf: [64]u8 = undefined,
    len: usize = 0,
    broke: bool = false,

    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *NestedServeCapture = @ptrCast(@alignCast(ctx.?));
        const bytes = switch (resolution) {
            .fulfilled => |value| value.bytes,
            .broken, .give => {
                self.broke = true;
                return;
            },
        };
        // Pump the second resolve through a nested serve — the same shape a
        // driver's `step` → `drainEvents` re-entry has — before reading.
        _ = self.port.serve(self.vat, self.inner_event) catch {
            self.broke = true;
            return;
        };
        @memcpy(self.buf[0..bytes.len], bytes);
        self.len = bytes.len;
    }
};

test "a far listener that pumps a second resolve through a nested serve reads intact bytes" {
    const allocator = std.testing.allocator;
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const host_peer = &pair.p1;
    const caller_peer = &pair.p2;

    var host_vat = actors.Vat.init(allocator);
    defer host_vat.deinit();
    var host_port = actors.Port.init(allocator, host_peer);
    defer host_port.deinit(&host_vat);
    const echo = try host_vat.spawn(EchoVerb, .{});
    try host_port.bindExport(&host_vat, echo, 5);
    try host_peer.exportObject(5);

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.init(allocator);
    defer caller_vat.deinit();
    var caller_port = actors.Port.init(allocator, caller_peer);
    defer caller_port.deinit(&caller_vat);
    const remote: actors.Ref = .{ .far = model.FarRef.object(5) };

    const first = try caller_port.send(&caller_vat, remote, .{ .verb = "one" });
    const second = try caller_port.send(&caller_vat, remote, .{ .verb = "two" });

    // Shuttle the delivers over (one step per frame), run both turns, then
    // shuttle the resolves back the same way.
    try cross_peer.pumpAll(caller_peer, host_peer);
    while (host_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try host_port.serve(&host_vat, &e);
    }
    try cross_peer.pumpAll(host_peer, caller_peer);

    var first_event = caller_peer.pollEvent() orelse return error.ExpectedResolve;
    defer first_event.deinit();
    var second_event = caller_peer.pollEvent() orelse return error.ExpectedResolve;
    defer second_event.deinit();

    var outer = NestedServeCapture{ .vat = &caller_vat, .port = &caller_port, .inner_event = &second_event };
    try caller_port.on(&caller_vat, first, .{ .ctx = &outer, .func = NestedServeCapture.record });
    var inner = Captured{};
    try caller_port.on(&caller_vat, second, .{ .ctx = &inner, .func = Captured.record });

    try std.testing.expect(try caller_port.serve(&caller_vat, &first_event));

    // Both resolutions read intact: the nested settle allocated in the same
    // arena but never reset it (depth returned to 1, not 0).
    try std.testing.expect(!outer.broke);
    try std.testing.expectEqualStrings("reply-one", outer.buf[0..outer.len]);
    try std.testing.expectEqualStrings("reply-two", inner.buf[0..inner.len]);
}

test "one converged wire resolve fires every local far listener" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var port = actors.Port.init(allocator, &peer);
    defer port.deinit(&vat);

    try peer.session_state.registerImport(.from(5));
    try peer.session_state.registerImport(.from(6));
    const shortening_five = model.ExportPosition.from(peer.session_state.next_export_position);
    try pancake.ocapn.engine.listen.ensureShorteningListener(&peer, .from(5));
    try pancake.ocapn.engine.listen.ensureShorteningListener(&peer, .from(6));
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const answer_five = try pancake.ocapn.engine.listen.listenOnFar(
        &peer,
        .{ .far = model.FarRef.promise(5) },
    );
    const answer_six = try pancake.ocapn.engine.listen.listenOnFar(
        &peer,
        .{ .far = model.FarRef.promise(6) },
    );
    const resolver_six = peer.session_state.outbound_resolver_link.getByValue(.{
        .application_answer = answer_six,
    }).?;
    var five = Captured{};
    var six = Captured{};
    try port.on(&vat, .{ .far = answer_five }, .{ .ctx = &five, .func = Captured.record });
    try port.on(&vat, .{ .far = answer_six }, .{ .ctx = &six, .func = Captured.record });
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const shortening_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(6) } },
    };
    var shortening = try pancake.ocapn.codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_five.int()) },
        .args = &shortening_args,
    } });
    defer shortening.deinit();
    try peer.recvBorrowed(shortening.view());

    const settlement_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .bytes = "shared" },
    };
    var settlement = try pancake.ocapn.codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver_six.int()) },
        .args = &settlement_args,
    } });
    defer settlement.deinit();
    try peer.recvBorrowed(settlement.view());
    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expect(try port.serve(&vat, &event));
    try std.testing.expectEqualStrings("shared", five.text());
    try std.testing.expectEqualStrings("shared", six.text());
}

/// A break listener that registers a NEW far promise mid-break; the drain
/// must fire it broken too — once the connection is gone, no resolution can
/// ever come.
const RegisterOnBreak = struct {
    vat: *actors.Vat,
    port: *actors.Port,
    late_broke: *bool,
    registered: bool = false,

    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *RegisterOnBreak = @ptrCast(@alignCast(ctx.?));
        if (resolution != .broken or self.registered) return;
        self.registered = true;
        const late = self.port.send(
            self.vat,
            .{ .far = model.FarRef.object(6) },
            .{ .verb = "late" },
        ) catch return;
        self.port.on(self.vat, late, .{ .ctx = self.late_broke, .func = promise_capture.captureBroken }) catch {};
    }
};

test "a far vow registered during breakFarVows also fires broken" {
    const allocator = std.testing.allocator;
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const caller_peer = &pair.p2;

    try caller_peer.importObject(5);
    try caller_peer.importObject(6);
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var port = actors.Port.init(allocator, caller_peer);
    defer port.deinit(&vat);

    const vow = try port.send(&vat, .{ .far = model.FarRef.object(5) }, .{ .verb = "poke" });
    var late_broke = false;
    var reactor = RegisterOnBreak{ .vat = &vat, .port = &port, .late_broke = &late_broke };
    try port.on(&vat, vow, .{ .ctx = &reactor, .func = RegisterOnBreak.record });

    // The whole listener map is detached before any fire; the mid-break
    // registration lands in the fresh map and the outer re-check drains it.
    port.breakFarVows("connection closed");
    try std.testing.expect(reactor.registered);
    try std.testing.expect(late_broke);
}
