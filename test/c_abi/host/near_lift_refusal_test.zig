//! A near call into a C behavior hands the caller's own values to the
//! callback, so its argument lift is borrowed: a refusal after an earlier
//! reference was claimed undoes that claim and nothing else. The Host sends
//! no wire release, the session stays open, and the callback never runs. The
//! custody is chosen at the C hosted callsite, so only a C consumer proves it.

const std = @import("std");
const c = @import("c_abi");
const cd = @import("c_abi_host");
const glowcap = @import("glowcap");
const actors = glowcap.actors;
const model = glowcap.ocapn.model;
const h = @import("harness.zig");

const Arg = c.GlowcapArgument;

const far7: model.Argument = .{ .reference = .{ .far = model.FarRef.object(7) } };
const far99: model.Argument = .{ .reference = .{ .far = model.FarRef.object(99) } };

fn countingBehavior(
    ctx: ?*anyopaque,
    _: ?*cd.GlowcapHostTurn,
    _: ?[*]const u8,
    _: usize,
    _: ?[*]const Arg,
    _: usize,
    out: *Arg,
) callconv(.c) i32 {
    const calls: *usize = @ptrCast(@alignCast(ctx.?));
    calls.* += 1;
    out.* = h.argStr("ok");
    return c.GLOWCAP_OK;
}

/// A Zig hosted object in the acceptor's session that near-calls the C
/// behavior with the arguments the test sets and records how that ended.
const Caller = struct {
    target: actors.Ref,
    args: []const model.Argument = &.{},
    ended: ?anyerror = null,
    runs: usize = 0,

    fn handle(erased: *anyopaque, turn: *actors.Turn, _: actors.Delivery) actors.HostedActor.Result {
        const self: *Caller = @ptrCast(@alignCast(erased));
        self.runs += 1;
        self.ended = null;
        _ = turn.near(self.target, .{ .verb = "go", .args = self.args }) catch |err| {
            self.ended = err;
        };
        return actors.HostedActor.Result.fromResult(@as(anyerror!model.Argument, .{ .void = {} }));
    }

    fn free(erased: *anyopaque) void {
        const self: *Caller = @ptrCast(@alignCast(erased));
        std.testing.allocator.destroy(self);
    }
};

const Rig = struct {
    hosts: [2]?*cd.GlowcapHost = undefined,
    dials: h.Dials = .{},
    watches: h.Watches = .{},
    pair: h.Pair = undefined,
    calls: usize = 0,
    caller: *Caller = undefined,
    caller_target: c.GlowcapReference = undefined,

    fn open(self: *Rig, seed: u8, designator: []const u8) !void {
        self.* = .{};
        const dialer = try h.newHost(seed);
        const acceptor = try h.newHost(seed + 1);
        self.hosts = .{ dialer, acceptor };
        self.pair = try h.openPair(&self.hosts, dialer, acceptor, designator, &self.dials, &self.watches);
        try h.expectOk(cd.glowcap_host_publish(acceptor, "near", 4, countingBehavior, &self.calls, null));
        self.caller = try std.testing.allocator.create(Caller);
        {
            var borrow = try cd.embedding.borrowForAttachment(acceptor);
            defer borrow.release();
            const host = borrow.core();
            self.caller.* = .{ .target = host.publications.get(host.publication_secret, "near").?.actor };
        }
        _ = try cd.testing.publishHosted(self.pair.b, "caller", .{ .ctx = self.caller, .handle = Caller.handle, .free = Caller.free });
        var fetched = h.CapturedSettle{};
        var ticket: u64 = undefined;
        try h.expectOk(cd.glowcap_host_session_fetch(self.pair.a, "caller", 6, &ticket));
        self.watches.add(dialer, ticket, &fetched);
        try self.pump();
        self.caller_target = try fetched.requireRef();
    }

    fn deinit(self: *Rig) void {
        for (self.hosts) |host| _ = cd.glowcap_host_release(host);
    }

    fn pump(self: *Rig) !void {
        try h.pump(&self.hosts, &.{self.pair}, &self.dials, &self.watches);
    }

    /// Tell the caller to run once, hand the dialer's frames to the acceptor
    /// without pumping, and return how many frames the acceptor then queued.
    fn run(self: *Rig, args: []const model.Argument) !usize {
        self.caller.args = args;
        try h.expectOk(cd.glowcap_host_session_tell(self.pair.a, &self.caller_target, "go", 2, null, 0));
        var stream: [8192]u8 = undefined;
        var len: usize = 0;
        while (true) {
            var frame: c.GlowcapManagedFrame = undefined;
            var prefix: [cd.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP]u8 = undefined;
            var prefix_len: usize = undefined;
            const rc = cd.glowcap_host_session_take_outbound(self.pair.a, &frame, &prefix, prefix.len, &prefix_len);
            if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) break;
            try h.expectOk(rc);
            defer c.glowcap_managed_frame_release(&frame);
            @memcpy(stream[len..][0..prefix_len], prefix[0..prefix_len]);
            len += prefix_len;
            @memcpy(stream[len..][0..frame.len], frame.bytes.?[0..frame.len]);
            len += frame.len;
        }
        try h.expectOk(cd.glowcap_host_session_feed_bytes(self.pair.b, &stream, len));
        var queued: usize = 0;
        while (true) {
            var frame: c.GlowcapManagedFrame = undefined;
            const rc = h.takeOutbound(self.pair.b, &frame);
            if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) break;
            try h.expectOk(rc);
            c.glowcap_managed_frame_release(&frame);
            queued += 1;
        }
        return queued;
    }
};

/// What the acceptor's session holds that a refused lift must leave alone.
const Held = struct {
    refcount: u64,
    absent: u64,
    live: usize,

    fn of(rig: *Rig) !Held {
        return .{
            .refcount = try cd.testing.importRefcount(rig.pair.b, 7),
            .absent = try cd.testing.importRefcount(rig.pair.b, 99),
            .live = try cd.testing.liveCapabilityCount(rig.hosts[1]),
        };
    }
};

fn expectRefusedKeepsEverything(rig: *Rig, args: []const model.Argument, expected: anyerror) !void {
    try cd.testing.importObject(rig.pair.b, 7);
    const held = try Held.of(rig);
    try std.testing.expect(held.refcount > 0);

    // A control call with no references fixes how many frames a call that
    // lifts nothing queues. The refusal must queue the same, so no wire
    // release for the claimed reference went out.
    const control = try rig.run(&.{});
    try std.testing.expectEqual(@as(usize, 0), control);
    try std.testing.expectEqual(@as(usize, 1), rig.caller.runs);
    try std.testing.expectEqual(@as(?anyerror, null), rig.caller.ended);
    try std.testing.expectEqual(@as(usize, 1), rig.calls);

    const queued = try rig.run(args);
    try std.testing.expectEqual(@as(usize, 2), rig.caller.runs);
    try std.testing.expectEqual(@as(?anyerror, expected), rig.caller.ended);
    try std.testing.expectEqual(@as(usize, 1), rig.calls);
    try std.testing.expectEqual(control, queued);
    try std.testing.expectEqual(held.refcount, (try Held.of(rig)).refcount);
    try std.testing.expectEqual(held.absent, (try Held.of(rig)).absent);
    try std.testing.expectEqual(held.live, (try Held.of(rig)).live);
    try std.testing.expectEqual(@as(c_int, 1), cd.glowcap_host_session_is_open(rig.pair.b));

    // The session carries on: the next call lifts nothing and reaches the callback.
    _ = try rig.run(&.{});
    try std.testing.expectEqual(@as(usize, 3), rig.caller.runs);
    try std.testing.expectEqual(@as(?anyerror, null), rig.caller.ended);
    try std.testing.expectEqual(@as(usize, 2), rig.calls);
    try rig.pump();
    try std.testing.expectEqual(@as(c_int, 1), cd.glowcap_host_session_is_open(rig.pair.b));
}

test "a near call whose later reference is not held is refused with the earlier claim undone and nothing sent" {
    var rig: Rig = undefined;
    try rig.open(0xc2, "127.0.0.1:8201");
    defer rig.deinit();
    try expectRefusedKeepsEverything(&rig, &.{ far7, far99 }, error.ForeignArgument);
}

test "a near call holding an inline give after a reference is refused with the claim undone and nothing sent" {
    var rig: Rig = undefined;
    try rig.open(0xc4, "127.0.0.1:8202");
    defer rig.deinit();
    var handoff: model.Handoff = .{ .give = .{
        .recipient_key = &(@as([32]u8, @splat(0x11))),
        .exporter = .{ .transport = "tcp", .designator = "127.0.0.1:9799", .hints = model.Hints.emptyFalse() },
        .gifter_exporter_session = &(@as([32]u8, @splat(0x22))),
        .gifter_side = &(@as([32]u8, @splat(0x33))),
        .gift_id = &(@as([model.handoff_gift_id_bytes]u8, @splat(0x44))),
        .signature = &(@as([64]u8, @splat(0x55))),
    } };
    try expectRefusedKeepsEverything(&rig, &.{ far7, .{ .handoff = &handoff } }, error.UnsupportedValue);
}
