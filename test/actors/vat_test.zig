//! Local actor model: spawn, near-call (`$`), eventual-send (`<-`) with
//! promises, and "become" expressed as mutating the actor's own state.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const Turn = actors.Turn;
const Message = actors.Message;

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

fn captureInt(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const slot: *i64 = @ptrCast(@alignCast(ctx.?));
    slot.* = switch (resolution) {
        .fulfilled => |value| value.integer,
        .broken, .give => -1,
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

    pub fn clone(self: *const CloneCounter, allocator: std.mem.Allocator) std.mem.Allocator.Error!*CloneCounter {
        const fresh = try allocator.create(CloneCounter);
        fresh.* = .{ .n = self.n };
        return fresh;
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

    pub fn clone(self: *const Ledger, allocator: std.mem.Allocator) std.mem.Allocator.Error!*Ledger {
        const fresh = try allocator.create(Ledger);
        errdefer allocator.destroy(fresh);
        const label = try allocator.dupe(u8, self.label);
        fresh.* = .{ .allocator = allocator, .label = label, .n = self.n };
        return fresh;
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

    // Arm the very next vat allocation to fail: that is `makeBox`'s
    // `create(Behavior)`, the first allocation `spawn` makes.
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
