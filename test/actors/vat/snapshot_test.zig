//! Local time-travel: snapshots share state copy-on-write, restore is
//! per-revision and reusable, deep-owning state round-trips leak-free,
//! persistent actors share without a clone method, functional become keeps
//! old revisions old, and an actor id is never reissued after restore.

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

    pub fn handle(self: *CloneCounter, turn: *Turn, msg: Delivery) !model.Argument {
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

    pub fn handle(self: *Ledger, turn: *Turn, msg: Delivery) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "label")) return .{ .bytes = self.label };
        if (std.mem.eql(u8, msg.verb, "relabel")) {
            const fresh = try self.allocator.dupe(u8, try msg.argBytes(0));
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

test "a persistent actor snapshots with no clone method (share-only)" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    const counter = try vat.spawn(PersistentCounter, .{ .n = 5 });
    // No `clone`, yet the snapshot succeeds: the persistent flavor is admitted by status-allow: pending state or quoted runtime label
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

/// A hundred distinct actors, each near-calling the next and each staging a `become`,
/// so all ten installs land as the stack unwinds. Every stage runs before any
/// install, so each one sees the same empty retire list: a reservation of one
/// slot per stage reserves one slot in total, not ten.
const ChainLink = struct {
    pub const snapshot_persistent = true;
    next: ?actors.Ref,
    n: i64,

    pub fn handle(self: *const ChainLink, turn: *Turn, msg: Delivery) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "go")) return error.NoSuchMethod;
        // Stage before descending, so every frame in the chain has a become
        // pending before the first one installs.
        try turn.become(ChainLink, .{ .next = self.next, .n = self.n + 1 });
        if (self.next) |next| _ = try turn.near(next, .{ .verb = "go" });
        return .{ .integer = self.n };
    }
};

test "a chain of nested becomes installs every one of them" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    var next: ?actors.Ref = null;
    var made: usize = 0;
    while (made < 100) : (made += 1) {
        next = try vat.spawn(ChainLink, .{ .next = next, .n = 0 });
    }

    _ = try vat.near(next.?, .{ .verb = "go" });
    // Every link ran once and became, so a second pass sees n == 1 throughout.
    try std.testing.expectEqual(@as(i64, 1), (try vat.near(next.?, .{ .verb = "go" })).integer);
}

test "an actor id is never reissued after a restore" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    var snap = try vat.snapshot();
    defer snap.deinit();

    // Spawn after the snapshot, then rewind past it. The actor is gone from the
    // heap, but an id is what the export table maps a wire position to, and that
    // table is not part of a snapshot: a partner handed this actor's id may
    // still be holding a capability that names it.
    const before = try vat.spawn(CloneCounter, .{ .n = 0 });
    try vat.restore(&snap);

    // So the next spawn must not be handed that id back. If the counter
    // rewound with the heap, this actor would answer for the one the partner
    // was granted.
    const after = try vat.spawn(CloneCounter, .{ .n = 7 });
    try std.testing.expect(before.local != after.local);
}

test "restore publishes its actor table before discarded state cleanup reenters" {
    const Trace = struct {
        subject: actors.Ref = undefined,
        created: ?actors.Ref = null,
        observed: ?i64 = null,
        drops: usize = 0,
    };
    const State = struct {
        pub const snapshot_persistent = true;
        vat: *actors.Vat,
        trace: *Trace,
        armed: bool = false,
        grow: bool,
        pub fn handle(self: *const @This(), turn: *Turn, msg: Delivery) !model.Argument {
            if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = @intFromBool(self.armed) };
            var next = self.*;
            next.armed = true;
            try turn.become(@This(), next);
            return .{ .void = {} };
        }
        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            if (!self.armed or self.vat.tearing_down) return;
            self.trace.drops += 1;
            const reply = self.vat.near(self.trace.subject, .{ .verb = "get" }) catch unreachable;
            self.trace.observed = reply.integer;
            const capacity = self.vat.actors.capacity();
            while (true) {
                self.trace.created = self.vat.spawn(Counter, .{ .n = 42 }) catch unreachable;
                if (!self.grow or self.vat.actors.capacity() != capacity) break;
            }
        }
    };
    for ([_]bool{ false, true }) |grow| {
        var vat = actors.Vat.init(std.testing.allocator);
        defer vat.deinit();
        var trace: Trace = .{};
        trace.subject = try vat.spawn(State, .{ .vat = &vat, .trace = &trace, .grow = grow });
        var snap = try vat.snapshot();
        defer snap.deinit();
        _ = try vat.near(trace.subject, .{ .verb = "arm" });
        try vat.restore(&snap);
        try std.testing.expectEqual(@as(usize, 1), trace.drops);
        try std.testing.expectEqual(@as(?i64, 0), trace.observed);
        try std.testing.expectEqual(@as(i64, 0), (try vat.near(trace.subject, .{ .verb = "get" })).integer);
        try std.testing.expectEqual(@as(i64, 42), (try vat.near(trace.created.?, .{ .verb = "get" })).integer);
    }
}
