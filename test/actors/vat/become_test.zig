//! Failure and become: a handler error discards the pending become while
//! pre-error mutations persist, spawn and settle OOM reclaim exactly, a
//! late listener is refused, and a reply held across a later become stays
//! readable.

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

/// The cross-actor half of the aliased-reply hazard. `AliasedBecomer` above
/// covers one actor reentering itself, where the reply at risk belongs to the
/// frame that unwinds. Here the two frames belong to actor B and the reply at
/// risk belongs to B's *first* frame, which has already returned by the time
/// B's second frame installs its become and frees the box those bytes borrow.
/// Severing the returning frame's reply cannot reach it: that frame has closed.
const Swappable = struct {
    pub const snapshot_persistent = true;
    label: [8]u8,

    pub fn handle(self: *const Swappable, turn: *Turn, msg: Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "peek")) return .{ .bytes = &self.label };
        return error.NoSuchMethod;
    }
};

const Swapper = struct {
    pub const snapshot_persistent = true;
    label: [8]u8,

    pub fn handle(self: *const Swapper, turn: *Turn, msg: Message) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "peek")) return .{ .bytes = &self.label };
        if (std.mem.eql(u8, msg.verb, "swap")) {
            try turn.become(Swapper, .{ .label = "new-name".* });
            return .{ .void = {} };
        }
        return error.NoSuchMethod;
    }
};

const Caller = struct {
    target: actors.Ref,

    pub fn handle(self: *const Caller, turn: *Turn, msg: Message) !model.Argument {
        _ = msg;
        // Hold the first reply across a second call that becomes.
        const peeked = try turn.near(self.target, .{ .verb = "peek" });
        _ = try turn.near(self.target, .{ .verb = "swap" });
        return peeked;
    }
};

test "a reply held across a later become on the same actor stays readable" {
    // Through the poisoning allocator: a freed state box usually still holds
    // its old bytes, so reading one back would otherwise produce the right
    // answer for the wrong reason and hide the defect.
    var wrapper: poison.PoisonOnFree = .{ .inner = std.testing.allocator };
    var vat = actors.Vat.init(wrapper.allocator());
    defer vat.deinit();

    const target = try vat.spawn(Swapper, .{ .label = "old-name".* });
    const caller = try vat.spawn(Caller, .{ .target = target });

    const reply = try vat.near(caller, .{ .verb = "go" });
    try std.testing.expectEqualStrings("old-name", reply.bytes);
    try std.testing.expectEqualStrings("new-name", (try vat.near(target, .{ .verb = "peek" })).bytes);
}
