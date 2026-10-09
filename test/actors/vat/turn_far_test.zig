//! A served turn's far sends leave only if the turn succeeds (ADR-0194): a
//! failed turn sends the caller its break and nothing else, breaks the vows of
//! the sends it retracted, and leaves the session's export and answer tables
//! as they were. Both profiles, because `next` pairs each answered send with
//! a resolver listener.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const promise_capture = @import("../../support/capture.zig");
const cross_peer = @import("../../support/cross_peer.zig");

const harness = @import("harness.zig");
const Counter = harness.Counter;
const ReentryMode = enum { none, local, far };

/// Sends `increment` back to the caller's counter twice, once with an answer
/// and once without, watches the answered vow, then fails or succeeds as the
/// verb asks.
const SendBack = struct {
    target: actors.Ref,
    broke: *bool,
    reentry: ?*Reentry = null,

    pub fn handle(self: *SendBack, turn: *Turn, msg: Message) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "recover")) {
            try turn.tell(self.target, .{ .verb = "increment" });
            return .{ .void = {} };
        }
        if (self.reentry != null) try turn.tell(self.target, .{ .verb = "increment" });
        const target = if (self.reentry) |listener| if (listener.mode == .local) listener.target else self.target else self.target;
        const vow = try turn.send(target, .{ .verb = "increment" });
        if (self.reentry) |listener|
            try turn.port.?.on(turn.vat, vow, .{ .ctx = listener, .func = Reentry.listen })
        else
            try turn.port.?.on(turn.vat, vow, .{ .ctx = self.broke, .func = promise_capture.captureBroken });
        try turn.tell(self.target, .{ .verb = "increment" });
        if (std.mem.eql(u8, msg.verb, "fail")) return error.Refused;
        return .{ .void = {} };
    }
};

const Reentry = struct {
    vat: *actors.Vat,
    port: *actors.Port,
    target: actors.Ref = undefined,
    broke: *bool,
    failed: bool = false,
    mode: ReentryMode,

    fn listen(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.broke.* = resolution == .broken;
        _ = self.vat.nearFromPort(self.port, .local, self.target, .{ .verb = "recover" }) catch {
            self.failed = true;
        };
    }
};

const Snapshot = struct {
    exports: usize,
    counter_retains: u64,
    outbound_answers: usize,

    fn of(peer: *engine.Peer) Snapshot {
        return .{
            .exports = peer.session_state.exports.len(),
            .counter_retains = peer.session_state.importRefcount(.from(7)),
            .outbound_answers = peer.session_state.outbound_answers.len(),
        };
    }
};

fn serveAll(peer: *engine.Peer, port: *actors.Port, vat: *actors.Vat) void {
    while (peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = port.serve(vat, &e) catch {};
    }
}

fn exercise(pair: *engine.pairing.Pair, verb: []const u8, reenter: ReentryMode) !struct { count: i64, caller_broke: bool, sender_broke: bool, before: Snapshot, after: Snapshot } {
    const allocator = std.testing.allocator;
    const host_peer = &pair.p1;
    const caller_peer = &pair.p2;

    var caller_vat = actors.Vat.init(allocator);
    defer caller_vat.deinit();
    var caller_port = actors.Port.init(allocator, caller_peer);
    defer caller_port.deinit(&caller_vat);
    const counter = try caller_vat.spawn(Counter, .{ .n = 0 });
    try caller_port.bindExport(&caller_vat, counter, 7);
    try caller_peer.exportObject(7);
    try host_peer.importObject(7);

    var host_vat = actors.Vat.init(allocator);
    defer host_vat.deinit();
    var host_port = actors.Port.init(allocator, host_peer);
    defer host_port.deinit(&host_vat);
    var sender_broke = false;
    var reentry: Reentry = .{ .vat = &host_vat, .port = &host_port, .broke = &sender_broke, .mode = reenter };
    const sender = try host_vat.spawn(SendBack, .{ .target = .{ .far = model.FarRef.object(7) }, .broke = &sender_broke, .reentry = if (reenter != .none) &reentry else null });
    reentry.target = sender;
    try host_port.bindExport(&host_vat, sender, 5);
    try host_peer.exportObject(5);
    try caller_peer.importObject(5);

    const before = Snapshot.of(host_peer);
    var caller_broke = false;
    const vow = try caller_port.send(&caller_vat, .{ .far = model.FarRef.object(5) }, .{ .verb = verb });
    try caller_port.on(&caller_vat, vow, .{ .ctx = &caller_broke, .func = promise_capture.captureBroken });
    try cross_peer.pumpAll(caller_peer, host_peer);
    serveAll(host_peer, &host_port, &host_vat);
    try std.testing.expect(!reentry.failed);
    try std.testing.expectEqual(@as(usize, 0), host_vat.turn_break_reservations);
    try std.testing.expectEqual(@as(usize, 0), host_vat.turn_breaks.items.len);
    try std.testing.expect(host_vat.turn_breaks.capacity * @sizeOf(std.meta.Elem(@TypeOf(host_vat.turn_breaks.items))) <= actors.steady_list_bytes);
    const after = Snapshot.of(host_peer);
    try cross_peer.pumpAll(host_peer, caller_peer);
    serveAll(caller_peer, &caller_port, &caller_vat);
    try caller_vat.drive();
    const count = (try caller_vat.near(counter, .{ .verb = "get" })).integer;
    return .{ .count = count, .caller_broke = caller_broke, .sender_broke = sender_broke, .before = before, .after = after };
}

fn pairFor(profile: model.CaptpVersion) !engine.pairing.Pair {
    return switch (profile) {
        .v1_0 => engine.pairing.pairedV1_0Syrup(std.testing.allocator),
        .next => engine.pairing.paired(std.testing.allocator),
    };
}

test "a failed served turn sends its caller the break and none of its far sends" {
    inline for (.{ model.CaptpVersion.v1_0, model.CaptpVersion.next }) |profile| {
        var pair = try pairFor(profile);
        defer pair.deinit();
        const result = try exercise(&pair, "fail", .none);
        try std.testing.expect(result.caller_broke);
        try std.testing.expectEqual(@as(i64, 0), result.count);
        // The retracted answered send's vow breaks with the turn's error.
        try std.testing.expect(result.sender_broke);
        try std.testing.expectEqualDeep(result.before, result.after);
    }
}

test "a successful served turn sends its far messages" {
    inline for (.{ model.CaptpVersion.v1_0, model.CaptpVersion.next }) |profile| {
        var pair = try pairFor(profile);
        defer pair.deinit();
        const result = try exercise(&pair, "ok", .none);
        try std.testing.expect(!result.caller_broke);
        try std.testing.expectEqual(@as(i64, 2), result.count);
        try std.testing.expect(!result.sender_broke);
    }
}

test "a far-send break listener cannot commit another send from the failed turn" {
    inline for (.{ model.CaptpVersion.v1_0, model.CaptpVersion.next }) |profile| {
        for ([_]ReentryMode{ .local, .far }) |mode| {
            var pair = try pairFor(profile);
            defer pair.deinit();
            const result = try exercise(&pair, "fail", mode);
            try std.testing.expect(result.caller_broke);
            try std.testing.expect(result.sender_broke);
            try std.testing.expectEqual(@as(i64, 1), result.count);
        }
    }
}

test "turn rollback allocates nothing and keeps pending failure listeners cancellable" {
    const Probe = struct {
        allocator: *std.testing.FailingAllocator,
        vat: *actors.Vat,
        port: *actors.Port,
        first: actors.Vow = undefined,
        cancelled: *bool,
        unexpected: *bool,

        fn firstBreak(ctx: ?*anyopaque, _: actors.Resolution) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.unexpected.* = true;
        }
        fn secondBreak(ctx: ?*anyopaque, _: actors.Resolution) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const listener = self.port.takeListener(self.vat, self.first) orelse return;
            self.cancelled.* = listener.ctx == ctx and listener.func == firstBreak;
        }
        pub fn handle(self: *@This(), turn: *Turn, _: Message) !model.Argument {
            const target: actors.Ref = .{ .far = model.FarRef.object(7) };
            self.first = try turn.send(target, .{ .verb = "first" });
            try self.port.on(turn.vat, self.first, .{ .ctx = self, .func = firstBreak });
            const second = try turn.send(target, .{ .verb = "second" });
            try self.port.on(turn.vat, second, .{ .ctx = self, .func = secondBreak });
            self.allocator.fail_index = self.allocator.alloc_index;
            return error.Refused;
        }
    };
    inline for (.{ model.CaptpVersion.v1_0, model.CaptpVersion.next }) |profile| {
        var pair = try pairFor(profile);
        defer pair.deinit();
        try pair.p2.exportObject(7);
        try pair.p1.importObject(7);
        const before = pair.p1.pending_send.pending().len;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var vat = actors.Vat.init(failing.allocator());
        defer vat.deinit();
        var port = actors.Port.init(failing.allocator(), &pair.p1);
        defer port.deinit(&vat);
        var cancelled = false;
        var unexpected = false;
        const actor = try vat.spawn(Probe, .{ .allocator = &failing, .vat = &vat, .port = &port, .cancelled = &cancelled, .unexpected = &unexpected });
        try std.testing.expectError(error.Refused, vat.nearFromPort(&port, .local, actor, .{ .verb = "fail" }));
        try std.testing.expect(!failing.has_induced_failure);
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(cancelled);
        try std.testing.expect(!unexpected);
        try std.testing.expectEqual(@as(usize, 0), port.far_listeners.count());
        try std.testing.expectEqual(before, pair.p1.pending_send.pending().len);
        try std.testing.expectEqual(@as(usize, 0), vat.turn_break_reservations);
    }
}
