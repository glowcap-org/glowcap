//! The turn itself: near-calls dispatch synchronously, cyclic chains refuse
//! before the stack does, become survives reentrancy, eventual-send settles
//! its promise, replies live in the turn arena across resets, and a
//! re-entrant drive runs each queued turn exactly once.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
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
/// at the outer frame's unwind, freeing the box the outer reply's bytes
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
    // The reply reflects the state the turn ran as, the old label, and its
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

test "a turn's local send built in turn.arena survives the next turn's arena reset" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const sink = try vat.spawn(Sink, .{});
    const forwarder = try vat.spawn(Forwarder, .{ .sink = sink });

    // Turn one builds the payload in the turn arena and queues a local send of
    // it. Turn two (the sink's) begins with a depth-0 turn-arena reset, so the
    // queued message must own its bytes (the queue-chunk clone) or the sink
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
