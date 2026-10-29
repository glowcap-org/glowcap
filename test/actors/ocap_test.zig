//! Object-capability forwarding proxies (ADR-0016): the caretaker (revocable
//! forwarder) and attenuator (verb allow-list) built on `Turn.forward`. The
//! local tests prove forwarding and refusal through `near`. The over-the-wire
//! test proves the deferred-answer path, a far caller delivers to a hosted
//! caretaker proxy, which forwards to its target and settles the caller's answer
//! when the forwarded send resolves, then breaks it once revoked.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const Delivery = actors.Delivery;
const capture = @import("../support/capture.zig");
const cross_peer = @import("../support/cross_peer.zig");

/// A counter target: `get` reads, `add` adds and returns the new total,
/// `increment` bumps. The verb set lets attenuation forward some and refuse
/// others.
const Counter = struct {
    n: i64,

    pub fn handle(self: *Counter, turn: *Turn, msg: Delivery) !model.Argument {
        _ = turn;
        if (msg.is("get")) return .{ .integer = self.n };
        if (msg.is("add")) {
            self.n += try msg.argInt(0);
            return .{ .integer = self.n };
        }
        if (msg.is("increment")) {
            self.n += 1;
            return .{ .void = {} };
        }
        return error.NoSuchMethod;
    }
};

test "a caretaker forwards until revoked, then breaks every call" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const target = try vat.spawn(Counter, .{ .n = 0 });
    const care = try actors.ocap.caretaker(&vat, target);

    // Live: the proxy forwards a near-call and returns the target's value.
    try std.testing.expectEqual(
        @as(i64, 5),
        (try vat.near(care.proxy, .{ .verb = "add", .args = &.{.{ .integer = 5 }} })).integer,
    );

    // Revoked: every call through the proxy breaks, and the target is untouched.
    care.revoke(&vat);
    try std.testing.expectError(
        actors.ocap.Error.Revoked,
        vat.near(care.proxy, .{ .verb = "add", .args = &.{.{ .integer = 100 }} }),
    );
    try std.testing.expectEqual(@as(i64, 5), (try vat.near(target, .{ .verb = "get" })).integer);
}

test "revoking a caretaker whose proxy row a restore dropped is a no-op" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var before = try vat.snapshot();
    defer before.deinit();

    const target = try vat.spawn(Counter, .{ .n = 0 });
    const care = try actors.ocap.caretaker(&vat, target);
    // A clone-less mutable proxy keeps the vat from being snapshotted.
    try std.testing.expectError(actors.Error.NotSnapshottable, vat.snapshot());

    // The restore drops both rows, so the revoke finds nothing to sever
    // instead of writing through freed state.
    try vat.restore(&before);
    care.revoke(&vat);
    try std.testing.expectError(actors.Error.NoSuchActor, vat.near(care.proxy, .{ .verb = "get" }));
}

test "an attenuator forwards only its allowed verbs" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const target = try vat.spawn(Counter, .{ .n = 0 });
    const view = try actors.ocap.attenuate(&vat, target, &.{ "get", "add" });

    try std.testing.expectEqual(@as(i64, 0), (try vat.near(view, .{ .verb = "get" })).integer);
    try std.testing.expectEqual(
        @as(i64, 7),
        (try vat.near(view, .{ .verb = "add", .args = &.{.{ .integer = 7 }} })).integer,
    );
    // An out-of-list verb is unrepresentable through this view.
    try std.testing.expectError(
        actors.ocap.Error.Attenuated,
        vat.near(view, .{ .verb = "increment" }),
    );
}

test "a caretaker composes over an attenuator: a revocable read-only view" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const target = try vat.spawn(Counter, .{ .n = 3 });
    const readonly = try actors.ocap.attenuate(&vat, target, &.{"get"});
    const care = try actors.ocap.caretaker(&vat, readonly);

    // Read forwards through both proxies; write is refused by the attenuator.
    try std.testing.expectEqual(@as(i64, 3), (try vat.near(care.proxy, .{ .verb = "get" })).integer);
    try std.testing.expectError(
        actors.ocap.Error.Attenuated,
        vat.near(care.proxy, .{ .verb = "increment" }),
    );

    // Revoke severs the outer caretaker before the attenuator is even consulted.
    care.revoke(&vat);
    try std.testing.expectError(
        actors.ocap.Error.Revoked,
        vat.near(care.proxy, .{ .verb = "get" }),
    );
}

/// Pump every queued frame from `from` to `to` and step `to` so it parses them.
fn pump(from: *glowcap.ocapn.engine.Peer, to: *glowcap.ocapn.engine.Peer) !void {
    try cross_peer.pumpAll(from, to);
}

fn serveAll(vat: *actors.Vat, port: *actors.Port, peer: *glowcap.ocapn.engine.Peer) void {
    while (peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = port.serve(vat, &e) catch {};
    }
}

test "a far caller reaches a hosted caretaker proxy, then breaks on revoke" {
    const allocator = std.testing.allocator;
    var pair = try glowcap.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const coord_peer = &pair.p1;
    const agent_peer = &pair.p2;

    // The coordinator hosts a local target and a caretaker proxy over it; the
    // proxy is the only thing the agent can reach (export 7).
    var coord_vat = actors.Vat.init(allocator);
    defer coord_vat.deinit();
    var coord_port = actors.Port.init(allocator, coord_peer);
    defer coord_port.deinit(&coord_vat);
    const target = try coord_vat.spawn(Counter, .{ .n = 0 });
    const care = try actors.ocap.caretaker(&coord_vat, target);
    try coord_port.bindExport(&coord_vat, care.proxy, 7);
    // Hand-wired pairing: the agent addresses position 7 out-of-band, so the
    // bound position takes an explicit grant.
    try coord_peer.exportObject(7);

    try agent_peer.importObject(7);
    var agent_vat = actors.Vat.init(allocator);
    defer agent_vat.deinit();
    var agent_port = actors.Port.init(allocator, agent_peer);
    defer agent_port.deinit(&agent_vat);

    // Live: the agent calls the proxy; the coordinator forwards to its local
    // target and the forwarded send's result settles the agent's far answer.
    const promise = try agent_port.send(&agent_vat, .{ .far = model.FarRef.object(7) }, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });
    var result: i64 = 0;
    try agent_port.on(&agent_vat, promise, .{ .ctx = &result, .func = capture.captureInt });

    try pump(agent_peer, coord_peer);
    serveAll(&coord_vat, &coord_port, coord_peer); // proxy forwards: queues the local send
    try coord_vat.drive(); // settles the forwarded send, resolving the agent's answer
    try pump(coord_peer, agent_peer);
    serveAll(&agent_vat, &agent_port, agent_peer);
    try std.testing.expectEqual(@as(i64, 5), result);

    // Revoked: the same call now breaks the agent's answer, and the forward
    // never reaches the target (its total stays 5).
    care.revoke(&coord_vat);
    const broken_promise = try agent_port.send(&agent_vat, .{ .far = model.FarRef.object(7) }, .{ .verb = "add", .args = &.{.{ .integer = 100 }} });
    var broke = false;
    try agent_port.on(&agent_vat, broken_promise, .{ .ctx = &broke, .func = capture.captureBroken });

    try pump(agent_peer, coord_peer);
    serveAll(&coord_vat, &coord_port, coord_peer); // proxy refuses: breaks the answer in place
    try pump(coord_peer, agent_peer);
    serveAll(&agent_vat, &agent_port, agent_peer);
    try std.testing.expect(broke);
    try std.testing.expectEqual(@as(i64, 5), (try coord_vat.near(target, .{ .verb = "get" })).integer);
}

test "a local eventual proxy defers to a far target and preserves no-answer tells" {
    const allocator = std.testing.allocator;
    var pair = try glowcap.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    var local = actors.Vat.init(allocator);
    defer local.deinit();
    var local_port = actors.Port.init(allocator, &pair.p1);
    defer local_port.deinit(&local);
    var remote = actors.Vat.init(allocator);
    defer remote.deinit();
    var remote_port = actors.Port.init(allocator, &pair.p2);
    defer remote_port.deinit(&remote);
    const target = try remote.spawn(Counter, .{ .n = 7 });
    try remote_port.bindExport(&remote, target, 9);
    try pair.p2.exportObject(9);
    try pair.p1.importObject(9);
    const proxy = try actors.ocap.caretaker(&local, .{ .far = model.FarRef.object(9) });

    // A synchronous caller still cannot cross the network.
    try std.testing.expectError(actors.Error.NotNearCallable, local.near(proxy.proxy, .{ .verb = "get" }));
    const answer = try local_port.send(&local, proxy.proxy, .{ .verb = "get" });
    var result: i64 = 0;
    try local.on(answer, .{ .ctx = &result, .func = capture.captureInt });
    try local.drive();
    try std.testing.expectEqual(@as(i64, 0), result);
    try pump(&pair.p1, &pair.p2);
    serveAll(&remote, &remote_port, &pair.p2);
    try pump(&pair.p2, &pair.p1);
    serveAll(&local, &local_port, &pair.p1);
    try std.testing.expectEqual(@as(i64, 7), result);
    try std.testing.expectEqual(@as(usize, 0), local.pending_local_vows.count());

    try local_port.tell(&local, proxy.proxy, .{ .verb = "increment" });
    try local.drive();
    try pump(&pair.p1, &pair.p2);
    var delivered = false;
    while (pair.p2.pollEvent()) |event| {
        var owned = event;
        defer owned.deinit();
        if (owned.view().* == .deliver) {
            delivered = true;
            try std.testing.expect(owned.deliverAnswerTarget() == null);
        }
        _ = try remote_port.serve(&remote, &owned);
    }
    try std.testing.expect(delivered);
    try std.testing.expectEqual(@as(i64, 8), (try remote.near(target, .{ .verb = "get" })).integer);
    try std.testing.expectEqual(@as(usize, 0), local.pending_local_vows.count());
}

test "a long local eventual forwarding chain settles without recursive listener calls" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();
    var target = try vat.spawn(Counter, .{ .n = 42 });
    for (0..4096) |_| target = (try actors.ocap.caretaker(&vat, target)).proxy;
    const answer = try vat.send(target, .{ .verb = "get" });
    var result: i64 = 0;
    try vat.on(answer, .{ .ctx = &result, .func = capture.captureInt });
    try vat.drive();
    try std.testing.expectEqual(@as(i64, 42), result);
    try std.testing.expectEqual(@as(usize, 0), vat.pending_local_vows.count());
}
