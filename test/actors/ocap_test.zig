//! Object-capability forwarding proxies (ADR-0064): the caretaker (revocable
//! forwarder) and attenuator (verb allow-list) built on `Turn.forward`. The
//! local tests prove forwarding and refusal through `near`; the over-the-wire
//! test proves the deferred-answer path, a far caller delivers to a hosted
//! caretaker proxy, which forwards to its target and settles the caller's answer
//! when the forwarded send resolves, then breaks it once revoked.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const capture = @import("../support/capture.zig");
const cross_peer = @import("../support/cross_peer.zig");

/// A counter target: `get` reads, `add` adds and returns the new total,
/// `increment` bumps. The verb set lets attenuation forward some and refuse
/// others.
const Counter = struct {
    n: i64,

    pub fn handle(self: *Counter, turn: *Turn, msg: Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        if (std.mem.eql(u8, msg.verb, "add")) {
            self.n += try msg.argInt(0);
            return .{ .integer = self.n };
        }
        if (std.mem.eql(u8, msg.verb, "increment")) {
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
    const care = try actors.caretaker(&vat, target);

    // Live: the proxy forwards a near-call and returns the target's value.
    try std.testing.expectEqual(
        @as(i64, 5),
        (try vat.near(care.proxy, .{ .verb = "add", .args = &.{.{ .integer = 5 }} })).integer,
    );

    // Revoked: every call through the proxy breaks, and the target is untouched.
    care.revoke();
    try std.testing.expectError(
        actors.ocap.Error.Revoked,
        vat.near(care.proxy, .{ .verb = "add", .args = &.{.{ .integer = 100 }} }),
    );
    try std.testing.expectEqual(@as(i64, 5), (try vat.near(target, .{ .verb = "get" })).integer);
}

test "an attenuator forwards only its allowed verbs" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const target = try vat.spawn(Counter, .{ .n = 0 });
    const view = try actors.attenuate(&vat, target, &.{ "get", "add" });

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
    const readonly = try actors.attenuate(&vat, target, &.{"get"});
    const care = try actors.caretaker(&vat, readonly);

    // Read forwards through both proxies; write is refused by the attenuator.
    try std.testing.expectEqual(@as(i64, 3), (try vat.near(care.proxy, .{ .verb = "get" })).integer);
    try std.testing.expectError(
        actors.ocap.Error.Attenuated,
        vat.near(care.proxy, .{ .verb = "increment" }),
    );

    // Revoke severs the outer caretaker before the attenuator is even consulted.
    care.revoke();
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
    const care = try actors.caretaker(&coord_vat, target);
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
    care.revoke();
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
