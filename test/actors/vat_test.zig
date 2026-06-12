//! Local actor model: spawn, near-call (`$`), eventual-send (`<-`) + promises,
//! and "become" expressed as mutating the actor's own state.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const Turn = actors.Turn;
const Message = actors.Message;

/// A counter whose `self` *is* its state — `increment`/`add` mutate it in place,
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

/// An actor that near-calls itself without bound — a stand-in for a cyclic local
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

fn captureInt(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const slot: *i64 = @ptrCast(@alignCast(ctx.?));
    slot.* = switch (resolution) {
        .fulfilled => |value| value.integer,
        .broken => -1,
    };
}

test "eventual-send resolves its promise and fires the listener" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 10 });
    const promise = try vat.send(counter, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });

    var result: i64 = 0;
    try vat.on(promise, .{ .ctx = &result, .func = captureInt });

    try vat.drive();
    try std.testing.expectEqual(@as(i64, 15), result);
}

fn captureBroken(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const slot: *bool = @ptrCast(@alignCast(ctx.?));
    slot.* = resolution == .broken;
}

test "a handler error settles the promise as broken" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(Counter, .{ .n = 0 });
    const promise = try vat.send(counter, .{ .verb = "no-such-method" });

    var broke = false;
    try vat.on(promise, .{ .ctx = &broke, .func = captureBroken });

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
            .broken => return,
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

/// An actor that, in its own turn, spawns a helper and near-calls it — proving
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

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.initOver(allocator, caller_peer);
    defer caller_vat.deinit();

    // Fire-and-forget: no answer requested, so the caller holds no promise.
    try caller_vat.tell(.{ .far = model.FarRef.object(5) }, .{ .verb = "increment" });

    _ = try caller_peer.step();
    while (caller_peer.takeOutbound()) |frame| try host_peer.feedInbound(frame);
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

test "breakFarPromises settles outstanding far promises broken" {
    const allocator = std.testing.allocator;
    var pair = try pancake.ocapn.engine.pairing.paired(allocator);
    defer pair.deinit();
    const caller_peer = &pair.p2;

    try caller_peer.importObject(5);
    var caller_vat = actors.Vat.initOver(allocator, caller_peer);
    defer caller_vat.deinit();

    // A far send the partner never answers: the promise stays pending until the
    // connection it rode on is gone.
    const promise = try caller_vat.send(.{ .far = model.FarRef.object(5) }, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });
    var broke = false;
    try caller_vat.on(promise, .{ .ctx = &broke, .func = captureBroken });

    // No resolution arrives; breaking the far promises fires the listener broken
    // rather than leaving the awaiter waiting on a reply that can never come.
    try std.testing.expect(!broke);
    caller_vat.breakFarPromises("connection closed");
    try std.testing.expect(broke);

    // Idempotent: a second break has nothing left to settle.
    caller_vat.breakFarPromises("connection closed");
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

/// Stores the bytes it is sent — but first it deliberately scribbles over the
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
        break :blk @ptrCast(@alignCast(cell.state));
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
