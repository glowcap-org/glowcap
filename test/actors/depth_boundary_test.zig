//! The nesting ceiling at the Vat's own Argument entries: a queued send, a
//! borrowed reply materialized for the caller, and an owned reply cloned
//! ahead of a replacement. These walk `model.Argument`, so they hold the
//! count the session holds (a leaf at `model.max_value_depth`, no container
//! there) and refuse a deeper tree as `ValueTooDeep` before any effect.
//! Each case asserts the admitted side ran, so a refusal is not a vacuous pass.

const std = @import("std");
const glowcap = @import("glowcap");
const shapes = @import("../support/depth_shapes.zig");
const fixture = @import("../support/peer_fixture.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const allocator = std.testing.allocator;

const Counting = struct {
    calls: *usize,
    pub fn handle(self: *Counting, _: *actors.Turn, _: actors.Delivery) !model.Argument {
        self.calls.* += 1;
        return .{ .void = {} };
    }
};

test "a queued send to a local actor refuses a tree past the ceiling before it queues" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (shapes.owned) |shape| for (shapes.sweep) |depth| {
        var vat = actors.Vat.init(allocator);
        defer vat.deinit();
        var calls: usize = 0;
        const target = try vat.spawn(Counting, .{ .calls = &calls });
        const args = try shapes.ownedArgs(arena.allocator(), depth, shape);
        const sent = vat.send(target, .{ .verb = "poke", .args = args });
        if (shapes.admitted(shape, depth)) {
            _ = try sent;
            try vat.drive();
            try std.testing.expectEqual(@as(usize, 1), calls);
        } else {
            try std.testing.expectError(error.ValueTooDeep, sent);
            try vat.drive();
            try std.testing.expectEqual(@as(usize, 0), calls);
        }
    };
}

/// Replies with a borrowed tree built in the turn arena.
const Viewed = struct {
    depth: usize,
    shape: shapes.Shape,
    pub fn handle(self: *Viewed, turn: *actors.Turn, _: actors.Delivery) !actors.HostedActor.Result {
        const args = try shapes.viewArgs(turn.arena, self.depth, self.shape);
        return .{ .viewed = try args.at(0) };
    }
};

test "a borrowed reply is materialized for the caller at the session's count" {
    for (shapes.all) |shape| for (shapes.sweep) |depth| {
        var vat = actors.Vat.init(allocator);
        defer vat.deinit();
        const actor = try vat.spawn(Viewed, .{ .depth = depth, .shape = shape });
        const result = vat.near(actor, .{ .verb = "reply" });
        if (shapes.admitted(shape, depth)) {
            _ = try result;
        } else {
            try std.testing.expectError(error.ValueTooDeep, result);
        }
    };
}

const Replacement = struct {
    pub fn handle(_: *Replacement, _: *actors.Turn, _: actors.Delivery) !model.Argument {
        return .{ .void = {} };
    }
};

/// Replies with an owned tree and replaces itself, so the reply is cloned
/// before the old state is freed.
const Replacing = struct {
    depth: usize,
    shape: shapes.Shape,
    pub fn handle(self: *Replacing, turn: *actors.Turn, _: actors.Delivery) !model.Argument {
        try turn.become(Replacement, .{});
        return (try shapes.ownedArgs(turn.arena, self.depth, self.shape))[0];
    }
};

test "an owned reply cloned ahead of a replacement holds the session's count" {
    for (shapes.owned) |shape| for (shapes.sweep) |depth| {
        var vat = actors.Vat.init(allocator);
        defer vat.deinit();
        const actor = try vat.spawn(Replacing, .{ .depth = depth, .shape = shape });
        const result = vat.near(actor, .{ .verb = "reply" });
        if (shapes.admitted(shape, depth)) {
            _ = try result;
        } else {
            try std.testing.expectError(error.ValueTooDeep, result);
        }
    };
}

const DeepReply = struct {
    /// Receives a queued tell each deep reply stages before it returns, so the
    /// turn has a committed effect beyond the handler's own state.
    counter: actors.Ref,
    pub fn handle(self: *DeepReply, turn: *actors.Turn, msg: actors.Delivery) !actors.HostedActor.Result {
        if (msg.is("viewed") or msg.is("returned")) try turn.tell(self.counter, .{ .verb = "bump" });
        if (msg.is("viewed")) {
            const args = try shapes.viewArgs(turn.arena, model.max_value_depth + 1, .leaf);
            return .{ .viewed = try args.at(0) };
        }
        if (msg.is("returned")) {
            const args = try shapes.ownedArgs(turn.arena, model.max_value_depth + 1, .leaf);
            return .{ .returned = args[0] };
        }
        return .{ .returned = .{ .integer = 7 } };
    }
};

test "a served handler's over-deep reply breaks its one answer, aborts nothing, and the next call is served" {
    var peer = fixture.openPeer(allocator);
    defer peer.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var port = actors.Port.init(allocator, &peer);
    defer port.deinit(&vat);
    var bumps: usize = 0;
    const counter = try vat.spawn(Counting, .{ .calls = &bumps });
    const actor = try vat.spawn(DeepReply, .{ .counter = counter });
    try port.bindExport(&vat, actor, 7);
    try peer.exportObject(7);

    const calls = [_]struct { frame: []const u8, answer: u64, broken: bool }{
        .{ .frame = "<10'op:deliver<11'desc:export7+>[6'viewed]1+<18'desc:import-object0+>1+>", .answer = 1, .broken = true },
        .{ .frame = "<10'op:deliver<11'desc:export7+>[8'returned]2+<18'desc:import-object0+>1+>", .answer = 2, .broken = true },
        .{ .frame = "<10'op:deliver<11'desc:export7+>[2'ok]3+<18'desc:import-object0+>1+>", .answer = 3, .broken = false },
    };
    for (calls) |call| {
        try peer.recvBorrowed(.{ .bytes = call.frame, .shape = .byte });
        var event = peer.pollEvent().?;
        defer event.deinit();
        try std.testing.expect(try port.serve(&vat, &event));
        try std.testing.expect(peer.lastAbort() == null);
        const stored = peer.session_state.peekResolutionNamed(.fromWire(.from(call.answer))).?;
        if (call.broken) {
            try std.testing.expectEqualStrings("ValueTooDeep", stored.@"break".message);
        } else {
            try std.testing.expectEqual(@as(i64, 7), stored.fulfill.integer);
        }
    }
    // Each deep reply's staged tell committed with its turn: the answer broke
    // and the effect still ran.
    try vat.drive();
    try std.testing.expectEqual(@as(usize, 2), bumps);
    const bytes = try fixture.drainOutbound(&peer, allocator);
    defer allocator.free(bytes);
}

test "a borrowed delivery past the ceiling is refused at the lend before the queue and a later one runs" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var peer = fixture.openPeer(allocator);
    defer peer.deinit();
    var port = actors.Port.init(allocator, &peer);
    defer port.deinit(&vat);
    var calls: usize = 0;
    const target = try vat.spawn(Counting, .{ .calls = &calls });

    const deep = try shapes.viewArgs(arena.allocator(), model.max_value_depth + 1, .leaf);
    const ok = try shapes.viewArgs(arena.allocator(), model.max_value_depth, .leaf);
    try std.testing.expectError(error.ValueTooDeep, port.tellDelivery(&vat, target, .{ .verb = "poke", .args = deep, .reference_slots = 0 }));
    try std.testing.expectError(error.ValueTooDeep, port.sendDelivery(&vat, target, .{ .verb = "poke", .args = deep, .reference_slots = 0 }));
    try vat.drive();
    try std.testing.expectEqual(@as(usize, 0), calls);
    try port.tellDelivery(&vat, target, .{ .verb = "poke", .args = ok, .reference_slots = 0 });
    try vat.drive();
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "a far delivery with references materializes at the ceiling and refuses past it with nothing sent" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var peer = fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.importObject(5);
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var port = actors.Port.init(allocator, &peer);
    defer port.deinit(&vat);
    const remote: actors.Ref = .{ .far = model.FarRef.object(5) };

    const deep = try shapes.viewArgs(arena.allocator(), model.max_value_depth + 1, .leaf);
    const ok = try shapes.viewArgs(arena.allocator(), model.max_value_depth, .leaf);
    try std.testing.expectError(error.ValueTooDeep, port.tellDelivery(&vat, remote, .{ .verb = "poke", .args = deep, .reference_slots = 1 }));
    try std.testing.expectError(error.ValueTooDeep, port.sendDelivery(&vat, remote, .{ .verb = "poke", .args = deep, .reference_slots = 1 }));
    try std.testing.expect(peer.lastAbort() == null);
    _ = try peer.step();
    try std.testing.expect(peer.takeOutbound() == null);
    try port.tellDelivery(&vat, remote, .{ .verb = "poke", .args = ok, .reference_slots = 1 });
    _ = try peer.step();
    var frame = peer.takeOutbound() orelse return error.TestUnexpectedResult;
    frame.deinit();
}

fn takeFrame(peer: *glowcap.ocapn.engine.Peer) !bool {
    _ = try peer.step();
    var frame = peer.takeOutbound() orelse return false;
    frame.deinit();
    return true;
}

test "a raw Port far send past the ceiling keeps ValueTooDeep, sends nothing, returns its reserved answer, and the next send works" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var peer = fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.importObject(5);
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    var port = actors.Port.init(allocator, &peer);
    defer port.deinit(&vat);
    const remote: actors.Ref = .{ .far = model.FarRef.object(5) };

    // A live answer for the pipelined entry, and a clean wire.
    const first = try port.send(&vat, remote, .{ .verb = "poke" });
    try std.testing.expect(try takeFrame(&peer));
    const pipelined = first.far;
    const answers = &peer.session_state.outbound_answers;
    const next = answers.nextPosition();

    const owned = try shapes.ownedArgs(arena.allocator(), model.max_value_depth + 1, .leaf);
    const views = try shapes.viewArgs(arena.allocator(), model.max_value_depth + 1, .leaf);
    const lent: actors.Delivery = .{ .verb = "poke", .args = views, .reference_slots = 0 };
    for (0..3) |_| {
        try std.testing.expectError(error.ValueTooDeep, port.send(&vat, remote, .{ .verb = "poke", .args = owned }));
        try std.testing.expectError(error.ValueTooDeep, port.tell(&vat, remote, .{ .verb = "poke", .args = owned }));
        try std.testing.expectError(error.ValueTooDeep, port.sendToAnswer(&vat, pipelined, .{ .verb = "poke", .args = owned }));
        try std.testing.expectError(error.ValueTooDeep, port.sendDelivery(&vat, remote, lent));
        try std.testing.expectError(error.ValueTooDeep, port.tellDelivery(&vat, remote, lent));
        // No reserved slot is left behind: the next mint is the same position.
        try std.testing.expectEqual(next, answers.nextPosition());
    }
    try std.testing.expect(!try takeFrame(&peer));
    try std.testing.expect(peer.lastAbort() == null);

    const healthy = try port.send(&vat, remote, .{ .verb = "poke" });
    try std.testing.expectEqual(next, healthy.far.position);
    try std.testing.expect(try takeFrame(&peer));
    const ok_views = try shapes.viewArgs(arena.allocator(), model.max_value_depth, .leaf);
    _ = try port.sendDelivery(&vat, remote, .{ .verb = "poke", .args = ok_views, .reference_slots = 0 });
    try std.testing.expect(try takeFrame(&peer));
}
