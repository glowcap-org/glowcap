//! Hosted actors: spawnHosted serves near-call, eventual-send, and rich
//! Turns, a hosting vat is not snapshottable, failed spawn and failed export
//! bind both reclaim, and breakWith answers a served frame with the
//! handler's own words.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const Delivery = actors.Delivery;
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

/// A hosted actor's state (ADR-0022): owned by the caller, reached only through
/// the C-ABI-shaped `HostedActor` callbacks. Stands in for a binding's hosted
/// object with a Zig thunk, `handle` gets the full `Turn`, so it can eventual-
/// send like a Zig actor. `free` reclaims the caller-owned state.
const HostedState = struct {
    allocator: std.mem.Allocator,
    n: i64,
    sink: ?actors.Ref = null,

    fn handle(ctx: *anyopaque, turn: *Turn, msg: Delivery) actors.HostedActor.Result {
        return actors.HostedActor.Result.fromResult(handleOwned(ctx, turn, msg));
    }
    fn handleOwned(ctx: *anyopaque, turn: *Turn, msg: Delivery) anyerror!model.Argument {
        const self: *HostedState = @ptrCast(@alignCast(ctx));
        if (msg.is("get")) return .{ .integer = self.n };
        if (msg.is("add")) {
            self.n += try msg.argInt(0);
            return .{ .integer = self.n };
        }
        if (msg.is("bump-sink")) {
            _ = try turn.send(self.sink.?, .{ .verb = "increment" });
            return .{ .void = {} };
        }
        return error.NoSuchMethod;
    }

    fn free(ctx: *anyopaque) void {
        const self: *HostedState = @ptrCast(@alignCast(ctx));
        self.allocator.destroy(self);
    }
};

test "spawnHosted hosts a hosted actor: near-call, eventual-send, and a rich-Turn send" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const sink = try vat.spawn(Counter, .{ .n = 0 });
    const state = try allocator.create(HostedState);
    state.* = .{ .allocator = allocator, .n = 10, .sink = sink };
    // The vat owns `state` from here: its box's `free` reclaims it at `deinit`
    // (the testing allocator would report a leak otherwise).
    const hosted = try vat.spawnHosted(.{ .ctx = state, .handle = HostedState.handle, .free = HostedState.free });

    // Near-call reaches the hosted behavior and its mutable, caller-owned state.
    try std.testing.expectEqual(@as(i64, 10), (try vat.near(hosted, .{ .verb = "get" })).integer);
    _ = try vat.near(hosted, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });
    try std.testing.expectEqual(@as(i64, 15), (try vat.near(hosted, .{ .verb = "get" })).integer);

    // An eventual-send to the hosted actor drives and settles through its handle.
    _ = try vat.send(hosted, .{ .verb = "add", .args = &.{.{ .integer = 100 }} });
    try vat.drive();
    try std.testing.expectEqual(@as(i64, 115), (try vat.near(hosted, .{ .verb = "get" })).integer);

    // The hosted handle uses the full Turn: it eventual-sends to a co-hosted
    // Zig actor. Drive runs that queued turn, so a hosted actor sends
    // exactly like a Zig one.
    _ = try vat.near(hosted, .{ .verb = "bump-sink" });
    try vat.drive();
    try std.testing.expectEqual(@as(i64, 1), (try vat.near(sink, .{ .verb = "get" })).integer);
}

test "a vat holding a hosted actor is not snapshottable" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const state = try allocator.create(HostedState);
    state.* = .{ .allocator = allocator, .n = 0 };
    _ = try vat.spawnHosted(.{ .ctx = state, .handle = HostedState.handle, .free = HostedState.free });

    // The vat cannot clone state it does not own, so snapshot refuses loud.
    try std.testing.expectError(actors.Error.NotSnapshottable, vat.snapshot());
}

test "spawnHosted whose box allocation fails still runs the hosted free" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var vat = actors.Vat.init(failing.allocator());
    defer vat.deinit();

    var freed = false;
    const F = struct {
        fn handle(ctx: *anyopaque, turn: *Turn, msg: Delivery) actors.HostedActor.Result {
            _ = ctx;
            _ = turn;
            _ = msg;
            return .{ .returned = .{ .void = {} } };
        }
        fn free(ctx: *anyopaque) void {
            const flag: *bool = @ptrCast(@alignCast(ctx));
            flag.* = true;
        }
    };

    // Arm the next vat allocation (makeHostedBox's box) to fail, so the spawn
    // fails before the actor is installed. The free-on-every-outcome contract
    // still reclaims the hosted ctx.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        vat.spawnHosted(.{ .ctx = &freed, .handle = F.handle, .free = F.free }),
    );
    try std.testing.expect(freed);
    failing.fail_index = std.math.maxInt(usize);
}

test "a failed export bind can discard the freshly spawned hosted actor" {
    var pair = try glowcap.ocapn.engine.pairing.paired(std.testing.allocator);
    defer pair.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var vat = actors.Vat.init(failing.allocator());
    defer vat.deinit();
    var port = actors.Port.init(failing.allocator(), &pair.p1);
    defer port.deinit(&vat);

    var freed = false;
    const F = struct {
        fn handle(_: *anyopaque, _: *Turn, _: Delivery) actors.HostedActor.Result {
            return .{ .returned = .{ .void = {} } };
        }
        fn free(ctx: *anyopaque) void {
            const flag: *bool = @ptrCast(@alignCast(ctx));
            flag.* = true;
        }
    };
    const actor = try vat.spawnHosted(.{ .ctx = &freed, .handle = F.handle, .free = F.free });

    // The next allocation is the first export-binding map. This is the exact
    // post-spawn failure `publishHosted` unwinds through `discardFreshActor`.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, port.bindExport(&vat, actor, 7));
    vat.discardFreshActor(actor);
    try std.testing.expect(freed);
    try std.testing.expectError(actors.Error.NoSuchActor, vat.near(actor, .{ .verb = "poke" }));
    failing.fail_index = std.math.maxInt(usize);
}

test "Turn.breakWith breaks a served answer with the handler's own words and refuses a local frame" {
    const allocator = std.testing.allocator;
    var pair = try glowcap.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const host_peer = &pair.p1;
    const caller_peer = &pair.p2;

    var host_vat = actors.Vat.init(allocator);
    defer host_vat.deinit();
    var host_port = actors.Port.init(allocator, host_peer);
    defer host_port.deinit(&host_vat);

    // A gate that refuses every call with its own diagnostic, then returns
    // normally: the staged break must win over the void return value.
    const Gate = struct {
        fn handle(ctx: *anyopaque, turn: *Turn, msg: Delivery) actors.HostedActor.Result {
            return actors.HostedActor.Result.fromResult(handleOwned(ctx, turn, msg));
        }
        fn handleOwned(ctx: *anyopaque, turn: *Turn, msg: Delivery) anyerror!model.Argument {
            _ = ctx;
            _ = msg;
            try turn.breakWith("Attenuated");
            return .{ .void = {} };
        }
    };
    var unused: u8 = 0;
    const gate = try host_vat.spawnHosted(.{ .ctx = &unused, .handle = Gate.handle, .free = null });
    try host_port.bindExport(&host_vat, gate, 5);
    // Hand-wired pairing: the caller addresses position 5 out-of-band, so the
    // bound position takes an explicit grant.
    try host_peer.exportObject(5);

    // A local frame's caller consumes the return value directly, so the break
    // has nowhere to land and is refused.
    try std.testing.expectError(actors.Error.NotLocal, host_vat.near(gate, .{ .verb = "poke" }));

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.init(allocator);
    defer caller_vat.deinit();
    var caller_port = actors.Port.init(allocator, caller_peer);
    defer caller_port.deinit(&caller_vat);

    const BreakCapture = struct {
        broke: bool = false,
        buf: [64]u8 = undefined,
        len: usize = 0,
        fn listener(ctx: ?*anyopaque, resolution: actors.Resolution) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            switch (resolution) {
                .broken => |message| {
                    self.broke = true;
                    @memcpy(self.buf[0..message.len], message);
                    self.len = message.len;
                },
                .fulfilled, .give => {},
            }
        }
    };
    const vow = try caller_port.send(&caller_vat, .{ .far = model.FarRef.object(5) }, .{ .verb = "poke" });
    var captured = BreakCapture{};
    try caller_port.on(&caller_vat, vow, .{ .ctx = &captured, .func = BreakCapture.listener });

    try cross_peer.pumpAll(caller_peer, host_peer);
    while (host_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try host_port.serve(&host_vat, &e);
    }
    try cross_peer.pumpAll(host_peer, caller_peer);
    while (caller_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try caller_port.serve(&caller_vat, &e);
    }

    // The break carries the handler's own diagnostic, not a generic reason.
    try std.testing.expect(captured.broke);
    try std.testing.expectEqualStrings("Attenuated", captured.buf[0..captured.len]);
}
