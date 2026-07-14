//! Local actor model: spawn, near-call (`$`), eventual-send (`<-`) with
//! promises, and "become" expressed as mutating the actor's own state.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const promise_capture = @import("../support/capture.zig");

/// A counter whose `self` *is* its state, `increment`/`add` mutate it in place,
/// the Zig-native "become".
const Counter = struct {
    n: i64,

    pub fn handle(self: *Counter, turn: *Turn, msg: Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        if (std.mem.eql(u8, msg.verb, "increment")) {
            self.n += 1;
            return .{ .void = {} };
        }
        if (std.mem.eql(u8, msg.verb, "add")) {
            self.n += msg.arg(0).integer;
            return .{ .integer = self.n };
        }
        return error.NoSuchMethod;
    }
};

test "near-call dispatches synchronously and become mutates state" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 0 });
    try std.testing.expectEqual(@as(i64, 0), (try vat.near(counter, .{ .verb = "get" })).integer);

    _ = try vat.near(counter, .{ .verb = "increment" });
    _ = try vat.near(counter, .{ .verb = "add", .args = &.{.{ .integer = 4 }} });

    try std.testing.expectEqual(@as(i64, 5), (try vat.near(counter, .{ .verb = "get" })).integer);
}

/// An actor that near-calls itself without bound, a stand-in for a cyclic local
/// actor graph. The vat's near-call depth cap must stop it with a typed error
/// instead of overflowing the native stack.
const SelfRecurser = struct {
    pub fn handle(self: *SelfRecurser, turn: *Turn, msg: Message) !model.Argument {
        _ = self;
        _ = msg;
        return turn.near(turn.me(), .{ .verb = "recurse" });
    }
};

test "a cyclic near-call chain is refused before overflowing the stack" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const r = try vat.spawn(SelfRecurser, .{});
    try std.testing.expectError(error.NearCallTooDeep, vat.near(r, .{ .verb = "recurse" }));
}

/// A persistent actor that becomes and then reentrant-near-calls itself, whose
/// inner frame also becomes. The outer frame reads its own `self` after the
/// reentrant call: a become installed at the inner frame's return would free the
/// box the outer frame still holds as `self`, so this read must still see the
/// original state and the install must wait for the outermost frame.
const ReentrantBecomer = struct {
    pub const snapshot_persistent = true;
    n: i64,

    pub fn handle(self: *const ReentrantBecomer, turn: *Turn, msg: Message) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        if (std.mem.eql(u8, msg.verb, "outer")) {
            try turn.become(ReentrantBecomer, .{ .n = self.n + 1 });
            _ = try turn.near(turn.me(), .{ .verb = "inner" });
            // Read after the reentrant inner become: the outer frame's box is
            // still live because the install is deferred to this outermost frame.
            return .{ .integer = self.n };
        }
        if (std.mem.eql(u8, msg.verb, "inner")) {
            try turn.become(ReentrantBecomer, .{ .n = self.n + 100 });
            return .{ .void = {} };
        }
        return error.NoSuchMethod;
    }
};

test "a reentrant near-call that becomes leaves the outer frame's self intact" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const a = try vat.spawn(ReentrantBecomer, .{ .n = 7 });
    // The outer handler reads self after a reentrant self-near-call that itself
    // becomes; deferring the install to the outermost frame keeps that read valid.
    const read = try vat.near(a, .{ .verb = "outer" });
    try std.testing.expectEqual(@as(i64, 7), read.integer);
    // The outermost frame runs last, so its become is the installed state; the
    // inner frame's staged become is superseded and freed, not leaked.
    try std.testing.expectEqual(@as(i64, 8), (try vat.near(a, .{ .verb = "get" })).integer);
}

/// The aliased-reply half of the reentrant-become hazard: the *outer* frame
/// stages no become of its own, so the inner frame's promoted become installs
/// at the outer frame's unwind — freeing the box the outer reply's bytes
/// borrow. The reply must be severed onto the turn arena, not returned raw.
const AliasedBecomer = struct {
    pub const snapshot_persistent = true;
    label: [8]u8,

    pub fn handle(self: *const AliasedBecomer, turn: *Turn, msg: Message) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "read")) return .{ .bytes = &self.label };
        if (std.mem.eql(u8, msg.verb, "outer")) {
            _ = try turn.near(turn.me(), .{ .verb = "inner" });
            return .{ .bytes = &self.label };
        }
        if (std.mem.eql(u8, msg.verb, "inner")) {
            try turn.become(AliasedBecomer, .{ .label = "new-name".* });
            return .{ .void = {} };
        }
        return error.NoSuchMethod;
    }
};

test "a reply aliasing state survives an inner reentrant become" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const a = try vat.spawn(AliasedBecomer, .{ .label = "old-name".* });
    // The reply reflects the state the turn ran as — the old label — and its
    // bytes stay live even though the inner become's install freed the old box
    // as the near-call returned.
    const reply = try vat.near(a, .{ .verb = "outer" });
    try std.testing.expectEqualStrings("old-name", reply.bytes);
    // The inner become did install: the next turn runs as the new state.
    try std.testing.expectEqualStrings("new-name", (try vat.near(a, .{ .verb = "read" })).bytes);
}

test "eventual-send resolves its promise and fires the listener" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 10 });
    const promise = try vat.send(counter, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });

    var result: i64 = 0;
    try vat.on(promise, .{ .ctx = &result, .func = promise_capture.captureInt });

    try vat.drive();
    try std.testing.expectEqual(@as(i64, 15), result);
}

test "a handler error settles the promise as broken" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 0 });
    const promise = try vat.send(counter, .{ .verb = "no-such-method" });

    var broke = false;
    try vat.on(promise, .{ .ctx = &broke, .func = promise_capture.captureBroken });

    try vat.drive();
    try std.testing.expect(broke);
}

/// A greeter whose reply is freshly built each turn, so it must allocate. It uses
/// `turn.arena` — the per-turn allocator the vat reclaims — proving a handler can
/// return heap-allocated storage without leaking and without freeing it itself.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *Turn, msg: Message) !model.Argument {
        _ = self;
        const greeting = try std.fmt.allocPrint(turn.arena, "hello, {s}", .{msg.arg(0).bytes});
        return .{ .bytes = greeting };
    }
};

const Captured = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *Captured = @ptrCast(@alignCast(ctx.?));
        const bytes = switch (resolution) {
            .fulfilled => |value| value.bytes,
            .broken, .give => return,
        };
        @memcpy(self.buf[0..bytes.len], bytes);
        self.len = bytes.len;
    }
};

test "a handler allocates its reply from turn.arena without leaking" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const greeter = try vat.spawn(Greeter, .{});

    // Drive several turns: each allocates a reply from the turn arena, which the
    // vat reclaims at the next turn. The testing allocator fails the test on any
    // leak, so a green run is the proof that the reply path frees.
    var captured = Captured{};
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const promise = try vat.send(greeter, .{ .verb = "greet", .args = &.{.{ .bytes = "world" }} });
        try vat.on(promise, .{ .ctx = &captured, .func = Captured.record });
        try vat.drive();
    }
    try std.testing.expectEqualStrings("hello, world", captured.buf[0..captured.len]);
}

/// An actor that, in its own turn, spawns a helper and near-calls it, proving
/// `Turn` carries spawn/call authority into a handler.
const Adder = struct {
    pub fn handle(self: *Adder, turn: *Turn, msg: Message) !model.Argument {
        _ = self;
        const helper = try turn.spawn(Counter, .{ .n = 0 });
        return turn.near(helper, .{ .verb = "add", .args = msg.args });
    }
};

test "an actor spawns and calls another within its turn" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const adder = try vat.spawn(Adder, .{});
    const reply = try vat.near(adder, .{ .verb = "compute", .args = &.{.{ .integer = 7 }} });
    try std.testing.expectEqual(@as(i64, 7), reply.integer);
}

test "local tell runs the turn with no observable promise" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 0 });
    // No promise returned; the turn still runs on drive and mutates state.
    try vat.tell(counter, .{ .verb = "increment" });
    try vat.tell(counter, .{ .verb = "increment" });
    try vat.drive();
    try std.testing.expectEqual(@as(i64, 2), (try vat.near(counter, .{ .verb = "get" })).integer);
}

/// A hosted actor's state (ADR-0071): owned by the caller, reached only through
/// the C-ABI-shaped `HostedActor` callbacks. Stands in for a binding's hosted
/// object with a Zig thunk — `handle` gets the full `Turn`, so it can eventual-
/// send like a native actor; `free` reclaims the caller-owned state.
const HostedState = struct {
    allocator: std.mem.Allocator,
    n: i64,
    sink: ?actors.Ref = null,

    fn handle(ctx: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument {
        const self: *HostedState = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        if (std.mem.eql(u8, msg.verb, "add")) {
            self.n += msg.arg(0).integer;
            return .{ .integer = self.n };
        }
        if (std.mem.eql(u8, msg.verb, "bump-sink")) {
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
    // native actor. Drive runs that queued turn, so a hosted actor sends
    // exactly like a native one.
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
        fn handle(ctx: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument {
            _ = ctx;
            _ = turn;
            _ = msg;
            return .{ .void = {} };
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

test "Turn.breakWith breaks a served answer with the handler's own words and refuses a local frame" {
    const allocator = std.testing.allocator;
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const host_peer = &pair.p1;
    const caller_peer = &pair.p2;

    var host_vat = actors.Vat.initOver(allocator, host_peer);
    defer host_vat.deinit();

    // A gate that refuses every call with its own diagnostic, then returns
    // normally: the staged break must win over the void return value.
    const Gate = struct {
        fn handle(ctx: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument {
            _ = ctx;
            _ = msg;
            try turn.breakWith("Attenuated");
            return .{ .void = {} };
        }
    };
    var unused: u8 = 0;
    const gate = try host_vat.spawnHosted(.{ .ctx = &unused, .handle = Gate.handle, .free = null });
    try host_vat.bindExport(gate, 5);
    // Hand-wired pairing: the caller addresses position 5 out-of-band, so the
    // bound position takes an explicit grant.
    try host_peer.exportObject(5);

    // A local frame's caller consumes the return value directly, so the break
    // has nowhere to land and is refused.
    try std.testing.expectError(actors.Error.NotLocal, host_vat.near(gate, .{ .verb = "poke" }));

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.initOver(allocator, caller_peer);
    defer caller_vat.deinit();

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
    const vow = try caller_vat.send(.{ .far = model.FarRef.object(5) }, .{ .verb = "poke" });
    var captured = BreakCapture{};
    try caller_vat.on(vow, .{ .ctx = &captured, .func = BreakCapture.listener });

    _ = try caller_peer.step();
    while (caller_peer.takeOutbound()) |frame| try host_peer.feedOwned(frame);
    _ = try host_peer.step();
    while (host_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try host_vat.serve(&e);
    }
    _ = try host_peer.step();
    while (host_peer.takeOutbound()) |frame| try caller_peer.feedOwned(frame);
    _ = try caller_peer.step();
    while (caller_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try caller_vat.serve(&e);
    }

    // The break carries the handler's own diagnostic, not a generic reason.
    try std.testing.expect(captured.broke);
    try std.testing.expectEqualStrings("Attenuated", captured.buf[0..captured.len]);
}

test "driveBudgeted runs at most N queued turns then yields the rest to the next call" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 0 });
    // Queue five turns; a budget of two must run exactly two, leave three.
    for (0..5) |_| try vat.tell(counter, .{ .verb = "increment" });

    try std.testing.expectEqual(actors.Vat.DriveProgress.more_pending, try vat.driveBudgeted(2));
    try std.testing.expectEqual(@as(i64, 2), (try vat.near(counter, .{ .verb = "get" })).integer);

    try std.testing.expectEqual(actors.Vat.DriveProgress.more_pending, try vat.driveBudgeted(2));
    try std.testing.expectEqual(@as(i64, 4), (try vat.near(counter, .{ .verb = "get" })).integer);

    // The remaining one turn fits the budget, so the queue drains fully.
    try std.testing.expectEqual(actors.Vat.DriveProgress.drained, try vat.driveBudgeted(2));
    try std.testing.expectEqual(@as(i64, 5), (try vat.near(counter, .{ .verb = "get" })).integer);

    // A drained queue reports `.drained` even with budget to spare.
    try std.testing.expectEqual(actors.Vat.DriveProgress.drained, try vat.driveBudgeted(2));
}

test "far tell delivers with no answer and the partner replies nothing" {
    const allocator = std.testing.allocator;
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const host_peer = &pair.p1;
    const caller_peer = &pair.p2;

    var host_vat = actors.Vat.initOver(allocator, host_peer);
    defer host_vat.deinit();
    const counter = try host_vat.spawn(Counter, .{ .n = 0 });
    try host_vat.bindExport(counter, 5);
    try host_peer.exportObject(5);

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.initOver(allocator, caller_peer);
    defer caller_vat.deinit();

    // Fire-and-forget: no answer requested, so the caller holds no promise.
    try caller_vat.tell(.{ .far = model.FarRef.object(5) }, .{ .verb = "increment" });

    _ = try caller_peer.step();
    while (caller_peer.takeOutbound()) |frame| try host_peer.feedOwned(frame);
    _ = try host_peer.step();
    while (host_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = host_vat.serve(&e) catch {};
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

    var host_vat = actors.Vat.initOver(allocator, host_peer);
    defer host_vat.deinit();
    const counter = try host_vat.spawn(Counter, .{ .n = 0 });
    try host_vat.bindExport(counter, 5);
    try host_peer.exportObject(5);

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.initOver(allocator, caller_peer);
    defer caller_vat.deinit();

    // A far send the host answers with the new count.
    const vow = try caller_vat.send(.{ .far = model.FarRef.object(5) }, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });

    // The deliver reaches the host, which runs the actor and resolves the answer.
    _ = try caller_peer.step();
    while (caller_peer.takeOutbound()) |frame| try host_peer.feedOwned(frame);
    _ = try host_peer.step();
    while (host_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = host_vat.serve(&e) catch {};
    }
    // The host's resolve travels back to the caller and is applied.
    _ = try host_peer.step();
    while (host_peer.takeOutbound()) |frame| try caller_peer.feedOwned(frame);
    _ = try caller_peer.step();
    // The caller pumps the resolve *before* registering `on`: it fires with no
    // listener and is dropped, and the outbound answer is now settled.
    while (caller_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = caller_vat.serve(&e) catch {};
    }

    // A listener registered now would never fire, so it is refused loud —
    // the wire-side mirror of the local arm's settled guard.
    var captured = Captured{};
    try std.testing.expectError(
        actors.Error.AlreadySettled,
        caller_vat.on(vow, .{ .ctx = &captured, .func = Captured.record }),
    );
    // The refusal is idempotent: a retried `on` hits the same wall instead of
    // slipping past a consumed marker into a listener that can never fire.
    try std.testing.expectError(
        actors.Error.AlreadySettled,
        caller_vat.on(vow, .{ .ctx = &captured, .func = Captured.record }),
    );
}

test "breakFarVows settles outstanding far vows broken" {
    const allocator = std.testing.allocator;
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const caller_peer = &pair.p2;

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.initOver(allocator, caller_peer);
    defer caller_vat.deinit();

    // A far send the partner never answers: the vow stays pending until the
    // connection it rode on is gone.
    const vow = try caller_vat.send(.{ .far = model.FarRef.object(5) }, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });
    var broke = false;
    try caller_vat.on(vow, .{ .ctx = &broke, .func = promise_capture.captureBroken });

    // No resolution arrives; breaking the far vows fires the listener broken
    // rather than leaving the awaiter waiting on a reply that can never come.
    try std.testing.expect(!broke);
    caller_vat.breakFarVows("connection closed");
    try std.testing.expect(broke);

    // Idempotent: a second break has nothing left to settle.
    caller_vat.breakFarVows("connection closed");
}

test "bindExport refuses a far ref with NotLocal" {
    const allocator = std.testing.allocator;
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();

    var vat = actors.Vat.initOver(allocator, &pair.p1);
    defer vat.deinit();

    // Only a local actor can answer an export position this vat hosts; a far
    // ref already lives on the partner.
    try std.testing.expectError(
        actors.Error.NotLocal,
        vat.bindExport(.{ .far = model.FarRef.object(3) }, 7),
    );
}

/// Forwards its argument to a sink with a fresh payload built in `turn.arena` —
/// the documented handler pattern for outgoing args. The queued send must
/// survive the turn-arena reset that opens the sink's own turn.
const Forwarder = struct {
    sink: actors.Ref,

    pub fn handle(self: *Forwarder, turn: *Turn, msg: Message) !model.Argument {
        const payload = try std.fmt.allocPrint(turn.arena, "payload-{s}", .{msg.arg(0).bytes});
        _ = try turn.send(self.sink, .{ .verb = "store", .args = &.{.{ .bytes = payload }} });
        return .{ .void = {} };
    }
};

/// Stores the bytes it is sent, but first it deliberately scribbles over the
/// turn arena, so a message that (wrongly) still borrowed reset arena storage
/// would arrive corrupted.
const Sink = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    pub fn handle(self: *Sink, turn: *Turn, msg: Message) !model.Argument {
        const filler = try turn.arena.alloc(u8, 256);
        @memset(filler, 'Z');
        const bytes = msg.arg(0).bytes;
        @memcpy(self.buf[0..bytes.len], bytes);
        self.len = bytes.len;
        return .{ .void = {} };
    }
};

test "a turn's local send built in turn.arena survives the next turn's arena reset" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const sink = try vat.spawn(Sink, .{});
    const forwarder = try vat.spawn(Forwarder, .{ .sink = sink });

    // Turn one builds the payload in the turn arena and queues a local send of
    // it. Turn two (the sink's) begins with a depth-0 turn-arena reset, so the
    // queued message must own its bytes (the queue-arena clone) or the sink
    // reads scribbled-over storage.
    try vat.tell(forwarder, .{ .verb = "forward", .args = &.{.{ .bytes = "intact" }} });
    try vat.drive();

    const sink_state: *Sink = blk: {
        const cell = vat.actors.get(sink.local) orelse return error.NoSuchActor;
        break :blk @ptrCast(@alignCast(cell.box.ptr));
    };
    try std.testing.expectEqualStrings("payload-intact", sink_state.buf[0..sink_state.len]);
}

/// Returns a fresh, distinct greeting from `turn.arena` each turn, so a stale
/// borrow of an earlier reply's storage cannot accidentally hold the same bytes.
const ArenaGreeter = struct {
    n: u32 = 0,

    pub fn handle(self: *ArenaGreeter, turn: *Turn, msg: Message) !model.Argument {
        _ = msg;
        self.n += 1;
        return .{ .bytes = try std.fmt.allocPrint(turn.arena, "greeting-{d}", .{self.n}) };
    }
};

const ReentrantCapture = struct {
    vat: *actors.Vat,
    buf: [64]u8 = undefined,
    len: usize = 0,
    broke: bool = false,

    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *ReentrantCapture = @ptrCast(@alignCast(ctx.?));
        const bytes = switch (resolution) {
            .fulfilled => |value| value.bytes,
            .give => return,
            .broken => {
                self.broke = true;
                return;
            },
        };
        // Open a top-level turn from inside the listener: its depth-0 reset
        // reclaims the turn arena the handler built the original reply in. The
        // resolution this listener holds must be the vat's clone, not a borrow
        // of that reset storage.
        self.vat.drive() catch {
            self.broke = true;
            return;
        };
        @memcpy(self.buf[0..bytes.len], bytes);
        self.len = bytes.len;
    }
};

/// Bumps a test-owned counter every handler run, so a re-entrant drive that
/// re-executes queued turns shows up as an inflated count without the test
/// reaching into vat internals.
const RunCounter = struct {
    runs: *u32,
    pub fn handle(self: *RunCounter, turn: *Turn, msg: Message) !model.Argument {
        _ = turn;
        _ = msg;
        self.runs.* += 1;
        return .{ .void = {} };
    }
};

/// A listener that opens a nested drive the first time it fires.
const DriveOnce = struct {
    vat: *actors.Vat,
    fired: bool = false,
    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        _ = resolution;
        const self: *DriveOnce = @ptrCast(@alignCast(ctx.?));
        if (self.fired) return;
        self.fired = true;
        self.vat.drive() catch {};
    }
};

test "a re-entrant drive runs each queued turn exactly once" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    var runs: u32 = 0;
    const counter = try vat.spawn(RunCounter, .{ .runs = &runs });
    // Two queued sends; the first's listener opens a nested drive while the
    // second is still pending. A drive that restarted at zero would re-run the
    // first (and the second would run under both drives): the shared cursor
    // must hold each to a single execution.
    const first = try vat.send(counter, .{ .verb = "poke" });
    _ = try vat.send(counter, .{ .verb = "poke" });
    var driver = DriveOnce{ .vat = &vat };
    try vat.on(first, .{ .ctx = &driver, .func = DriveOnce.record });
    try vat.drive();

    try std.testing.expect(driver.fired);
    try std.testing.expectEqual(@as(u32, 2), runs);
}

test "a local listener that re-enters drive still reads an intact fulfilled value" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const greeter = try vat.spawn(ArenaGreeter, .{});
    const promise = try vat.send(greeter, .{ .verb = "greet" });

    var capture = ReentrantCapture{ .vat = &vat };
    try vat.on(promise, .{ .ctx = &capture, .func = ReentrantCapture.record });
    try vat.drive();

    try std.testing.expect(!capture.broke);
    try std.testing.expectEqualStrings("greeting-1", capture.buf[0..capture.len]);
}

// --- Local time-travel: snapshot / restore -------------------------------
//
// Tier 2 (copy-on-write) covers mutable actors that opt into snapshots with a
// `clone` method; tier 3 (functional become) covers persistent actors that
// never mutate `self`. The testing allocator fails any test that leaks, so a
// green run is also the proof that every shared box and every clone is freed
// exactly once.

/// A mutable counter that opts into snapshots with a deep `clone`. Its `self`
/// is its state, the tier-2 flavor: the vat copies-on-write a shared box before
/// a turn mutates it.
const CloneCounter = struct {
    n: i64,

    pub fn handle(self: *CloneCounter, turn: *Turn, msg: Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        if (std.mem.eql(u8, msg.verb, "increment")) {
            self.n += 1;
            return .{ .void = {} };
        }
        return error.NoSuchMethod;
    }

    pub fn clone(self: *const CloneCounter, allocator: std.mem.Allocator) std.mem.Allocator.Error!CloneCounter {
        _ = allocator;
        return .{ .n = self.n };
    }
};

fn getN(vat: *actors.Vat, ref: actors.Ref) !i64 {
    return (try vat.near(ref, .{ .verb = "get" })).integer;
}

test "snapshot shares state and copy-on-write isolates a later mutation" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(CloneCounter, .{ .n = 0 });
    _ = try vat.near(counter, .{ .verb = "increment" }); // n = 1

    var snap = try vat.snapshot();
    defer snap.deinit();

    // The next turn mutates a *shared* box, so copy-on-write must clone it first;
    // the snapshot's copy keeps n = 1.
    _ = try vat.near(counter, .{ .verb = "increment" }); // live n = 2
    try std.testing.expectEqual(@as(i64, 2), try getN(&vat, counter));

    try vat.restore(&snap);
    try std.testing.expectEqual(@as(i64, 1), try getN(&vat, counter));
}

test "two independent snapshots each restore their own revision and are reusable" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(CloneCounter, .{ .n = 0 });

    var s0 = try vat.snapshot(); // n = 0
    defer s0.deinit();
    _ = try vat.near(counter, .{ .verb = "increment" }); // n = 1
    var s1 = try vat.snapshot(); // n = 1
    defer s1.deinit();
    _ = try vat.near(counter, .{ .verb = "increment" }); // n = 2

    try vat.restore(&s0);
    try std.testing.expectEqual(@as(i64, 0), try getN(&vat, counter));
    try vat.restore(&s1);
    try std.testing.expectEqual(@as(i64, 1), try getN(&vat, counter));
    // Reusable: the same snapshot restores again.
    try vat.restore(&s0);
    try std.testing.expectEqual(@as(i64, 0), try getN(&vat, counter));
}

test "a non-cloneable, non-persistent actor makes snapshot fail NotSnapshottable" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    // `Counter` (above) defines no `clone` and is not persistent.
    const counter = try vat.spawn(Counter, .{ .n = 0 });
    try std.testing.expectError(actors.Error.NotSnapshottable, vat.snapshot());
    // The vat is left usable: the failed snapshot shared nothing it kept.
    _ = try vat.near(counter, .{ .verb = "increment" });
    try std.testing.expectEqual(@as(i64, 1), try getN(&vat, counter));
}

test "snapshot and restore refuse a non-quiescent vat with NotQuiescent" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(CloneCounter, .{ .n = 0 });
    // A queued (undriven) send leaves the vat non-quiescent.
    _ = try vat.send(counter, .{ .verb = "increment" });
    try std.testing.expectError(actors.Error.NotQuiescent, vat.snapshot());

    // A snapshot taken at quiescence cannot be restored mid-queue either.
    try vat.drive();
    var snap = try vat.snapshot();
    defer snap.deinit();
    _ = try vat.send(counter, .{ .verb = "increment" });
    try std.testing.expectError(actors.Error.NotQuiescent, vat.restore(&snap));
    try vat.drive();
}

/// A mutable actor whose state owns heap (a label), so a snapshot must deep-copy
/// it on write and a restore must free the live copy, the leak check is the
/// assertion.
const Ledger = struct {
    allocator: std.mem.Allocator,
    label: []u8,
    n: i64 = 0,

    pub fn handle(self: *Ledger, turn: *Turn, msg: Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "label")) return .{ .bytes = self.label };
        if (std.mem.eql(u8, msg.verb, "relabel")) {
            const fresh = try self.allocator.dupe(u8, msg.arg(0).bytes);
            self.allocator.free(self.label);
            self.label = fresh;
            self.n += 1;
            return .{ .void = {} };
        }
        return error.NoSuchMethod;
    }

    pub fn clone(self: *const Ledger, allocator: std.mem.Allocator) std.mem.Allocator.Error!Ledger {
        const label = try allocator.dupe(u8, self.label);
        return .{ .allocator = allocator, .label = label, .n = self.n };
    }

    pub fn deinit(self: *Ledger, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

test "snapshot deep-copies heap-owning state and restores it leak-free" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const ledger = try vat.spawn(Ledger, .{ .allocator = allocator, .label = try allocator.dupe(u8, "v0") });

    var snap = try vat.snapshot();
    defer snap.deinit();

    // Relabel mutates a shared, heap-owning box: copy-on-write must deep-clone
    // the label so freeing the live "v1" never touches the snapshot's "v0".
    _ = try vat.near(ledger, .{ .verb = "relabel", .args = &.{.{ .bytes = "v1" }} });
    try std.testing.expectEqualStrings("v1", (try vat.near(ledger, .{ .verb = "label" })).bytes);

    try vat.restore(&snap);
    try std.testing.expectEqualStrings("v0", (try vat.near(ledger, .{ .verb = "label" })).bytes);
}

/// A persistent actor (tier 3): it never mutates `self`, producing its next
/// state with `turn.become`. It defines no `clone`, so a snapshot can only admit
/// it via the persistent (share-only) path.
const PersistentCounter = struct {
    pub const snapshot_persistent = true;
    n: i64,

    pub fn handle(self: *const PersistentCounter, turn: *Turn, msg: Message) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        if (std.mem.eql(u8, msg.verb, "increment")) {
            try turn.become(PersistentCounter, .{ .n = self.n + 1 });
            return .{ .void = {} };
        }
        if (std.mem.eql(u8, msg.verb, "bump-then-fail")) {
            // Stage a become, then error: the staged value must be discarded.
            try turn.become(PersistentCounter, .{ .n = 999 });
            return error.Boom;
        }
        return error.NoSuchMethod;
    }
};

test "a persistent actor snapshots with no clone method (share-only)" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(PersistentCounter, .{ .n = 5 });
    // No `clone`, yet the snapshot succeeds: the persistent flavor is admitted by
    // sharing alone, which `NotSnapshottable` would reject for a mutable actor.
    var snap = try vat.snapshot();
    defer snap.deinit();
    try std.testing.expectEqual(@as(i64, 5), try getN(&vat, counter));
}

test "functional become installs the new value while snapshots keep the old" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(PersistentCounter, .{ .n = 0 });
    _ = try vat.near(counter, .{ .verb = "increment" }); // become -> 1

    var snap = try vat.snapshot(); // shares the n = 1 value
    defer snap.deinit();

    _ = try vat.near(counter, .{ .verb = "increment" }); // become -> 2, new box
    try std.testing.expectEqual(@as(i64, 2), try getN(&vat, counter));

    try vat.restore(&snap);
    try std.testing.expectEqual(@as(i64, 1), try getN(&vat, counter));
}

/// A persistent actor whose reply aliases its own heap state while it becomes a
/// fresh state in the same turn. The become frees this box when the turn
/// unwinds, so the reply — a borrow into that box — would dangle unless the vat
/// severs it onto the turn arena before promoting. The label is a separate heap
/// allocation freed by `deinit`, so a stale read lands on memory the testing
/// allocator has already reclaimed.
const AliasingSwapper = struct {
    pub const snapshot_persistent = true;
    allocator: std.mem.Allocator,
    label: []u8,

    pub fn handle(self: *const AliasingSwapper, turn: *Turn, msg: Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "swap")) return error.NoSuchMethod;
        // Reply with the current label (borrowed from this box's state), then
        // transition to the next. The next label's heap moves into the new box;
        // a failed become frees it here rather than leaking.
        const reply = model.Argument{ .bytes = self.label };
        const next = try self.allocator.dupe(u8, msg.arg(0).bytes);
        turn.become(AliasingSwapper, .{ .allocator = self.allocator, .label = next }) catch |err| {
            self.allocator.free(next);
            return err;
        };
        return reply;
    }

    pub fn deinit(self: *AliasingSwapper, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

test "a reply aliasing state survives a same-turn become" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const swapper = try vat.spawn(AliasingSwapper, .{
        .allocator = allocator,
        .label = try allocator.dupe(u8, "alpha"),
    });

    // Near-call: the returned reply must still read "alpha" after the become
    // freed the box "alpha" lived in. Read it before any later top-level turn
    // resets the arena the severed copy lives in.
    const near_reply = try vat.near(swapper, .{ .verb = "swap", .args = &.{.{ .bytes = "beta" }} });
    try std.testing.expectEqualStrings("alpha", near_reply.bytes);

    // Eventual-send + drive: `settleLocal` clones the reply, reading the box the
    // become freed unless `callLocal` severed it first.
    var captured = Captured{};
    const promise = try vat.send(swapper, .{ .verb = "swap", .args = &.{.{ .bytes = "gamma" }} });
    try vat.on(promise, .{ .ctx = &captured, .func = Captured.record });
    try vat.drive();
    try std.testing.expectEqualStrings("beta", captured.buf[0..captured.len]);
}

/// A mutable actor that swaps its owned label for a fresh one and hands the old
/// buffer to the reply with `turn.moveOut` — the headline use of the move: an
/// O(1) transfer where copying the buffer onto the turn arena would be O(len).
/// No `become` in sight; the move stands on its own.
const BufferHandoff = struct {
    allocator: std.mem.Allocator,
    label: []u8,

    pub fn handle(self: *BufferHandoff, turn: *Turn, msg: Message) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "swap")) {
            const reply = try turn.moveOut(&self.label);
            self.label = try self.allocator.dupe(u8, msg.arg(0).bytes);
            return reply;
        }
        if (std.mem.eql(u8, msg.verb, "swap-then-fail")) {
            _ = try turn.moveOut(&self.label);
            return error.Boom;
        }
        if (std.mem.eql(u8, msg.verb, "len")) return .{ .integer = @intCast(self.label.len) };
        return error.NoSuchMethod;
    }

    pub fn clone(self: *const BufferHandoff, allocator: std.mem.Allocator) std.mem.Allocator.Error!BufferHandoff {
        return .{ .allocator = self.allocator, .label = try allocator.dupe(u8, self.label) };
    }

    pub fn deinit(self: *BufferHandoff, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

test "moveOut transfers the reply buffer with zero copies (pointer identity)" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const original = try allocator.dupe(u8, "alpha");
    const actor = try vat.spawn(BufferHandoff, .{ .allocator = allocator, .label = original });

    // The near reply is the very allocation the state held — moved, not copied.
    const near_reply = try vat.near(actor, .{ .verb = "swap", .args = &.{.{ .bytes = "beta" }} });
    try std.testing.expectEqualStrings("alpha", near_reply.bytes);
    try std.testing.expectEqual(@intFromPtr(original.ptr), @intFromPtr(near_reply.bytes.ptr));

    // The eventual path still reads the moved bytes live: the vat frees them
    // only when its next outermost turn begins.
    var captured = Captured{};
    const promise = try vat.send(actor, .{ .verb = "swap", .args = &.{.{ .bytes = "gamma" }} });
    try vat.on(promise, .{ .ctx = &captured, .func = Captured.record });
    try vat.drive();
    try std.testing.expectEqualStrings("beta", captured.buf[0..captured.len]);
}

test "a handler error after moveOut leaks nothing and leaves the field cleared" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const actor = try vat.spawn(BufferHandoff, .{
        .allocator = allocator,
        .label = try allocator.dupe(u8, "alpha"),
    });
    // The moved bytes are vat-held from the moment `moveOut` returns, so the
    // error path frees them on schedule (the testing allocator would report a
    // leak otherwise); the cleared field stays cleared — mutable-actor state
    // changes never roll back.
    try std.testing.expectError(error.Boom, vat.near(actor, .{ .verb = "swap-then-fail" }));
    try std.testing.expectEqual(@as(i64, 0), (try vat.near(actor, .{ .verb = "len" })).integer);
}

test "moveOut under a live snapshot moves the copy-on-write clone, not the shared state" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const actor = try vat.spawn(BufferHandoff, .{
        .allocator = allocator,
        .label = try allocator.dupe(u8, "v0"),
    });
    var snap = try vat.snapshot();
    defer snap.deinit();

    // The mutating turn runs against the copy-on-write clone, so the buffer
    // `moveOut` hands the vat is the clone's — the snapshot's "v0" is never
    // moved or freed under it.
    const reply = try vat.near(actor, .{ .verb = "swap", .args = &.{.{ .bytes = "v1" }} });
    try std.testing.expectEqualStrings("v0", reply.bytes);

    try vat.restore(&snap);
    const restored = try vat.near(actor, .{ .verb = "swap", .args = &.{.{ .bytes = "v2" }} });
    try std.testing.expectEqualStrings("v0", restored.bytes);
}

/// A mutable actor that `become`s while its reply rides `moveOut` — the moved
/// bytes are vat-owned, so they outlive the old box with no sever-copy.
const MovingSwapper = struct {
    allocator: std.mem.Allocator,
    label: []u8,

    pub fn handle(self: *MovingSwapper, turn: *Turn, msg: Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "swap")) return error.NoSuchMethod;
        const reply = try turn.moveOut(&self.label);
        try turn.become(MovingSwapper, .{
            .allocator = self.allocator,
            .label = try self.allocator.dupe(u8, msg.arg(0).bytes),
        });
        return reply;
    }

    pub fn deinit(self: *MovingSwapper, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

test "moveOut hands an owned reply to the vat with no sever-copy across a become" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const original = try allocator.dupe(u8, "alpha");
    const swapper = try vat.spawn(MovingSwapper, .{ .allocator = allocator, .label = original });

    // Pointer identity across the become: the reply is the moved allocation
    // itself, proving the sever-copy was skipped and the become still landed.
    const near_reply = try vat.near(swapper, .{ .verb = "swap", .args = &.{.{ .bytes = "beta" }} });
    try std.testing.expectEqualStrings("alpha", near_reply.bytes);
    try std.testing.expectEqual(@intFromPtr(original.ptr), @intFromPtr(near_reply.bytes.ptr));

    var captured = Captured{};
    const promise = try vat.send(swapper, .{ .verb = "swap", .args = &.{.{ .bytes = "gamma" }} });
    try vat.on(promise, .{ .ctx = &captured, .func = Captured.record });
    try vat.drive();
    try std.testing.expectEqualStrings("beta", captured.buf[0..captured.len]);
}

/// A mutable actor that moves one field out but replies with a borrow of a
/// *different* field, and `become`s. The moved bytes are vat-owned, but the
/// reply is not them — it borrows the old box, which the become frees — so the
/// vat must still sever it. The pointer-identity gate in `callLocal` is what
/// this pins: `moveOut` must never blanket-disable the sever for a reply it
/// does not actually own.
const MisdirectedMover = struct {
    allocator: std.mem.Allocator,
    scratch: []u8,
    label: []u8,

    pub fn handle(self: *MisdirectedMover, turn: *Turn, msg: Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "swap")) return error.NoSuchMethod;
        _ = try turn.moveOut(&self.scratch);
        try turn.become(MisdirectedMover, .{
            .allocator = self.allocator,
            .scratch = try self.allocator.dupe(u8, "scratch"),
            .label = try self.allocator.dupe(u8, msg.arg(0).bytes),
        });
        return .{ .bytes = self.label };
    }

    pub fn deinit(self: *MisdirectedMover, allocator: std.mem.Allocator) void {
        allocator.free(self.scratch);
        allocator.free(self.label);
    }
};

test "a reply borrowing state other than the moved bytes is still severed across a become" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const mover = try vat.spawn(MisdirectedMover, .{
        .allocator = allocator,
        .scratch = try allocator.dupe(u8, "scratch"),
        .label = try allocator.dupe(u8, "alpha"),
    });

    // The reply borrows `label` in the box the become frees; without the
    // sever this reads freed memory (the testing allocator poisons it).
    const near_reply = try vat.near(mover, .{ .verb = "swap", .args = &.{.{ .bytes = "beta" }} });
    try std.testing.expectEqualStrings("alpha", near_reply.bytes);

    var captured = Captured{};
    const promise = try vat.send(mover, .{ .verb = "swap", .args = &.{.{ .bytes = "gamma" }} });
    try vat.on(promise, .{ .ctx = &captured, .func = Captured.record });
    try vat.drive();
    try std.testing.expectEqualStrings("beta", captured.buf[0..captured.len]);
}

/// A mutable actor that moves TWO fields out in one turn and replies with the
/// FIRST, then `become`s. The sever gate scans every allocation the turn
/// moved — not just the last — so this reply is recognized as vat-owned and
/// returned with pointer identity, no sever-copy.
const DoubleMover = struct {
    allocator: std.mem.Allocator,
    first: []u8,
    second: []u8,

    pub fn handle(self: *DoubleMover, turn: *Turn, msg: Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "swap")) return error.NoSuchMethod;
        const reply = try turn.moveOut(&self.first);
        _ = try turn.moveOut(&self.second);
        try turn.become(DoubleMover, .{
            .allocator = self.allocator,
            .first = try self.allocator.dupe(u8, msg.arg(0).bytes),
            .second = try self.allocator.dupe(u8, msg.arg(0).bytes),
        });
        return reply;
    }

    pub fn deinit(self: *DoubleMover, allocator: std.mem.Allocator) void {
        allocator.free(self.first);
        allocator.free(self.second);
    }
};

test "a turn that moves two fields and returns the first still skips the sever" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const original = try allocator.dupe(u8, "alpha");
    const mover = try vat.spawn(DoubleMover, .{
        .allocator = allocator,
        .first = original,
        .second = try allocator.dupe(u8, "sigma"),
    });

    // Pointer identity across the become: the reply is the first moved
    // allocation itself. A last-move-only gate would miss it and pay a
    // spurious (safe) sever-copy; the whole-turn scan recognizes it.
    const reply = try vat.near(mover, .{ .verb = "swap", .args = &.{.{ .bytes = "beta" }} });
    try std.testing.expectEqualStrings("alpha", reply.bytes);
    try std.testing.expectEqual(@intFromPtr(original.ptr), @intFromPtr(reply.bytes.ptr));
}

/// The `moveOutString` mirror of `MovingSwapper`: the moved buffer returns as
/// a `string` argument and still outlives a same-turn become with no copy.
const StringSwapper = struct {
    allocator: std.mem.Allocator,
    label: []u8,

    pub fn handle(self: *StringSwapper, turn: *Turn, msg: Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "swap")) return error.NoSuchMethod;
        const reply = try turn.moveOutString(&self.label);
        try turn.become(StringSwapper, .{
            .allocator = self.allocator,
            .label = try self.allocator.dupe(u8, msg.arg(0).bytes),
        });
        return reply;
    }

    pub fn deinit(self: *StringSwapper, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

const StringCapture = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *StringCapture = @ptrCast(@alignCast(ctx.?));
        const text = switch (resolution) {
            .fulfilled => |value| if (value == .string) value.string else return,
            .broken, .give => return,
        };
        @memcpy(self.buf[0..text.len], text);
        self.len = text.len;
    }
};

test "moveOutString hands an owned string reply to the vat with no sever-copy across a become" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const original = try allocator.dupe(u8, "alpha");
    const swapper = try vat.spawn(StringSwapper, .{ .allocator = allocator, .label = original });

    // The near reply is the very allocation the state held, returned through
    // the string arm — the sever gate covers `.string` exactly as `.bytes`.
    const near_reply = try vat.near(swapper, .{ .verb = "swap", .args = &.{.{ .bytes = "beta" }} });
    try std.testing.expectEqualStrings("alpha", near_reply.string);
    try std.testing.expectEqual(@intFromPtr(original.ptr), @intFromPtr(near_reply.string.ptr));

    // The eventual path clones the string for the listener like any reply.
    var captured = StringCapture{};
    const promise = try vat.send(swapper, .{ .verb = "swap", .args = &.{.{ .bytes = "gamma" }} });
    try vat.on(promise, .{ .ctx = &captured, .func = StringCapture.record });
    try vat.drive();
    try std.testing.expectEqualStrings("beta", captured.buf[0..captured.len]);
}

/// A mutable actor whose reply borrows its own heap label; `relabel` frees
/// that label and installs a fresh same-size one, so a resolution that still
/// borrowed the state would read freed (and likely reused) memory.
const LabelHolder = struct {
    allocator: std.mem.Allocator,
    label: []u8,

    pub fn handle(self: *LabelHolder, turn: *Turn, msg: Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .bytes = self.label };
        if (std.mem.eql(u8, msg.verb, "relabel")) {
            const fresh = try self.allocator.dupe(u8, msg.arg(0).bytes);
            self.allocator.free(self.label);
            self.label = fresh;
            return .{ .void = {} };
        }
        return error.NoSuchMethod;
    }

    pub fn deinit(self: *LabelHolder, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

/// A listener that first drives the rest of the queue — running a turn that
/// mutates the very state the resolution's value was borrowed from — and only
/// then reads the resolution bytes.
const MutateThenRead = struct {
    vat: *actors.Vat,
    buf: [64]u8 = undefined,
    len: usize = 0,
    broke: bool = false,

    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *MutateThenRead = @ptrCast(@alignCast(ctx.?));
        const bytes = switch (resolution) {
            .fulfilled => |value| value.bytes,
            .broken, .give => {
                self.broke = true;
                return;
            },
        };
        // The nested drive runs the queued `relabel`, which frees the actor
        // label the handler's reply borrowed. The resolution this listener
        // holds must be the vat's settle clone, never that borrow.
        self.vat.drive() catch {
            self.broke = true;
            return;
        };
        @memcpy(self.buf[0..bytes.len], bytes);
        self.len = bytes.len;
    }
};

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
        _ = self.vat.serve(self.inner_event) catch {
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

    var host_vat = actors.Vat.initOver(allocator, host_peer);
    defer host_vat.deinit();
    const echo = try host_vat.spawn(EchoVerb, .{});
    try host_vat.bindExport(echo, 5);
    try host_peer.exportObject(5);

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.initOver(allocator, caller_peer);
    defer caller_vat.deinit();
    const remote: actors.Ref = .{ .far = model.FarRef.object(5) };

    const first = try caller_vat.send(remote, .{ .verb = "one" });
    const second = try caller_vat.send(remote, .{ .verb = "two" });

    // Shuttle the delivers over (one step per frame), run both turns, then
    // shuttle the resolves back the same way.
    while (true) {
        _ = try caller_peer.step();
        const frame = caller_peer.takeOutbound() orelse break;
        try host_peer.feedOwned(frame);
        _ = try host_peer.step();
    }
    while (host_peer.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = try host_vat.serve(&e);
    }
    while (true) {
        _ = try host_peer.step();
        const frame = host_peer.takeOutbound() orelse break;
        try caller_peer.feedOwned(frame);
        _ = try caller_peer.step();
    }

    var first_event = caller_peer.pollEvent() orelse return error.ExpectedResolve;
    defer first_event.deinit();
    var second_event = caller_peer.pollEvent() orelse return error.ExpectedResolve;
    defer second_event.deinit();

    var outer = NestedServeCapture{ .vat = &caller_vat, .inner_event = &second_event };
    try caller_vat.on(first, .{ .ctx = &outer, .func = NestedServeCapture.record });
    var inner = Captured{};
    try caller_vat.on(second, .{ .ctx = &inner, .func = Captured.record });

    try std.testing.expect(try caller_vat.serve(&first_event));

    // Both resolutions read intact: the nested settle allocated in the same
    // arena but never reset it (depth returned to 1, not 0).
    try std.testing.expect(!outer.broke);
    try std.testing.expectEqualStrings("reply-one", outer.buf[0..outer.len]);
    try std.testing.expectEqualStrings("reply-two", inner.buf[0..inner.len]);
}

/// A break listener that registers a NEW far promise mid-break; the drain
/// must fire it broken too — once the connection is gone, no resolution can
/// ever come.
const RegisterOnBreak = struct {
    vat: *actors.Vat,
    late_broke: *bool,
    registered: bool = false,

    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *RegisterOnBreak = @ptrCast(@alignCast(ctx.?));
        if (resolution != .broken or self.registered) return;
        self.registered = true;
        const late = self.vat.send(
            .{ .far = model.FarRef.object(6) },
            .{ .verb = "late" },
        ) catch return;
        self.vat.on(late, .{ .ctx = self.late_broke, .func = promise_capture.captureBroken }) catch {};
    }
};

test "a far vow registered during breakFarVows also fires broken" {
    const allocator = std.testing.allocator;
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const caller_peer = &pair.p2;

    try caller_peer.importObject(5);
    try caller_peer.importObject(6);
    var vat = actors.Vat.initOver(allocator, caller_peer);
    defer vat.deinit();

    const vow = try vat.send(.{ .far = model.FarRef.object(5) }, .{ .verb = "poke" });
    var late_broke = false;
    var reactor = RegisterOnBreak{ .vat = &vat, .late_broke = &late_broke };
    try vat.on(vow, .{ .ctx = &reactor, .func = RegisterOnBreak.record });

    // The whole listener map is detached before any fire; the mid-break
    // registration lands in the fresh map and the outer re-check drains it.
    vat.breakFarVows("connection closed");
    try std.testing.expect(reactor.registered);
    try std.testing.expect(late_broke);
}

test "a handler error discards the pending become" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(PersistentCounter, .{ .n = 7 });
    try std.testing.expectError(error.Boom, vat.near(counter, .{ .verb = "bump-then-fail" }));
    // The staged become(999) was discarded; the actor keeps its prior state.
    try std.testing.expectEqual(@as(i64, 7), try getN(&vat, counter));
}

/// An actor that owns a heap blob and records that its `deinit` ran, so a spawn
/// that fails can prove `makeBox` reclaimed the state it was handed.
const OwnsBlob = struct {
    ran: *bool,
    blob: []u8,
    blob_allocator: std.mem.Allocator,

    pub fn handle(self: *OwnsBlob, turn: *Turn, msg: Message) !model.Argument {
        _ = self;
        _ = turn;
        _ = msg;
        return error.NoSuchMethod;
    }

    pub fn deinit(self: *OwnsBlob, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.ran.* = true;
        self.blob_allocator.free(self.blob);
    }
};

test "spawn whose first allocation fails reclaims the initial state (makeBox contract)" {
    // The vat runs on a failing allocator; the blob the actor owns is drawn
    // from the leak-checking allocator, so an unreclaimed blob is a reported
    // leak, not just a silent drop.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var vat = actors.Vat.init(failing.allocator());
    defer vat.deinit();

    var ran = false;
    const blob = try std.testing.allocator.alloc(u8, 16);

    // Arm the very next vat allocation to fail: that is `makeBox`'s one
    // merged box+state block, the first allocation `spawn` makes.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        vat.spawn(OwnsBlob, .{ .ran = &ran, .blob = blob, .blob_allocator = std.testing.allocator }),
    );
    // `makeBox` ran the actor's `deinit`, which freed the blob; nothing leaks.
    try std.testing.expect(ran);

    // Disarm so vat teardown allocates freely (a failed alloc leaves the index
    // parked on `fail_index`, failing every later allocation otherwise).
    failing.fail_index = std.math.maxInt(usize);
}

fn markFiredAny(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    _ = resolution;
    const flag: *bool = @ptrCast(@alignCast(ctx.?));
    flag.* = true;
}

test "an OOM at the settle clone leaves the listener parked, never orphaned" {
    // Sweep a failing allocator across every allocation index of one listened
    // local send episode (Greeter's reply is arena bytes, so the settle clone
    // in `settleLocal` must allocate). For each index exactly one outcome is
    // legal: the episode completed and the listener fired, or it failed with
    // OutOfMemory and the listener is either unfired-but-still-parked in the
    // map (the peek-then-remove contract: teardown can still reach its
    // context) or was never registered. A removed-but-unfired listener —
    // the orphan the old remove-then-clone order produced — fails the sweep.
    // The listener context is heap so the leak-checking allocator would also
    // report a context stranded off the map.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var vat = actors.Vat.init(failing.allocator());
        defer vat.deinit();

        const fired = try std.testing.allocator.create(bool);
        defer std.testing.allocator.destroy(fired);
        fired.* = false;

        var saw_oom = false;
        var listened = false;
        setup: {
            const greeter = vat.spawn(Greeter, .{}) catch {
                saw_oom = true;
                break :setup;
            };
            const promise = vat.send(greeter, .{ .verb = "greet", .args = &.{.{ .bytes = "sweep" }} }) catch {
                saw_oom = true;
                break :setup;
            };
            vat.on(promise, .{ .ctx = fired, .func = markFiredAny }) catch {
                saw_oom = true;
                break :setup;
            };
            listened = true;
            if (vat.drive()) |_| {
                try std.testing.expect(fired.*);
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                saw_oom = true;
            }
        }
        if (listened and !fired.*) {
            // The settle failed mid-clone: the listener must still be parked,
            // not removed-and-unfired.
            try std.testing.expectEqual(@as(usize, 1), vat.listeners.count());
        }
        // Disarm so vat teardown allocates freely.
        failing.fail_index = std.math.maxInt(usize);
        if (!saw_oom) break;
        // The episode is a bounded handful of allocations; a sweep that never
        // completes means something regressed into an allocation storm.
        try std.testing.expect(fail_index < 256);
    }
}

test "a listener registered after the promise settled is refused" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 0 });
    const promise = try vat.send(counter, .{ .verb = "increment" });
    try vat.drive();

    // The promise settled in that drive; a listener parked now could never
    // fire, so `on` refuses loudly instead of stranding it.
    var fired = false;
    try std.testing.expectError(
        actors.Error.AlreadySettled,
        vat.on(promise, .{ .ctx = &fired, .func = markFiredAny }),
    );

    // A promise minted after the settlement registers normally.
    const next = try vat.send(counter, .{ .verb = "increment" });
    try vat.on(next, .{ .ctx = &fired, .func = markFiredAny });
    try vat.drive();
    try std.testing.expect(fired);
}

/// A mutable actor whose failing verb mutates `self` *before* erroring: the
/// pin for the module-header contract that mutable turns are not
/// transactional — the write survives while the caller sees the break. The
/// persistent flavor's mirror pin is "a handler error discards the pending
/// become" above.
const MutateThenFail = struct {
    n: i64,

    pub fn handle(self: *MutateThenFail, turn: *Turn, msg: Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        if (std.mem.eql(u8, msg.verb, "bump-then-fail")) {
            self.n += 1;
            return error.Boom;
        }
        return error.NoSuchMethod;
    }
};

test "a mutable actor's pre-error mutation persists while the promise breaks" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const a = try vat.spawn(MutateThenFail, .{ .n = 7 });
    const promise = try vat.send(a, .{ .verb = "bump-then-fail" });
    var broke = false;
    try vat.on(promise, .{ .ctx = &broke, .func = promise_capture.captureBroken });
    try vat.drive();

    // The caller sees the break…
    try std.testing.expect(broke);
    // …and the half-applied mutation survives: mutable `self` writes are not
    // rolled back on a handler error. All-or-nothing turns are the persistent
    // flavor's contract, not this one's. Drift toward rollback here must be a
    // deliberate design change.
    try std.testing.expectEqual(@as(i64, 8), (try vat.near(a, .{ .verb = "get" })).integer);
}
