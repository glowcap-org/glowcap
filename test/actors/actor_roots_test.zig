//! Actor roots and reclamation at the Vat tier (ADR-0014): the explicit root
//! count on each actor row, the deferred retire that keeps a running turn and
//! its borrowed reply safe, the typed refusal a queued turn takes when its
//! target was reclaimed, and restore's intersect-never-resurrect rule. The
//! Host-composition rooting relationships (aliases, capability slots, export
//! bindings, gift rows) are proven in `test/driver/core_host/`.

const std = @import("std");
const glowcap = @import("glowcap");
const promise_capture = @import("../support/capture.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;

/// A stateful probe whose deinit raises a flag, so a test observes exactly
/// when the Vat let go of the state box.
const Probe = struct {
    freed: *bool,

    pub fn handle(self: *Probe, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = self;
        _ = turn;
        if (!msg.is("ping")) return error.NoSuchMethod;
        return .{ .string = "pong" };
    }

    pub fn deinit(self: *Probe, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.freed.* = true;
    }

    pub fn clone(self: *const Probe, allocator: std.mem.Allocator) !Probe {
        _ = allocator;
        return .{ .freed = self.freed };
    }
};

const SiblingReleaser = struct {
    vat: *actors.Vat,
    sibling: actors.Ref,
    freed: *bool,

    pub fn handle(_: *SiblingReleaser, _: *actors.Turn, _: actors.Delivery) !model.Argument {
        return .{ .void = {} };
    }

    pub fn deinit(self: *SiblingReleaser, _: std.mem.Allocator) void {
        self.vat.releaseActor(self.sibling.local);
        self.freed.* = true;
    }
};

test "releasing the spawn root reclaims an idle actor at the outermost-turn boundary" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    var freed = false;
    const probe = try vat.spawn(Probe, .{ .freed = &freed });
    const id = probe.local;

    // A retain/release pair leaves the spawn root in place.
    vat.retainActor(id);
    vat.releaseActor(id);
    try std.testing.expect(vat.hasActor(id));

    // Releasing the spawn root removes the row at once, but the box parks
    // until the next outermost turn begins, the borrowed reply's lifetime.
    vat.releaseActor(id);
    try std.testing.expect(!vat.hasActor(id));
    try std.testing.expect(!freed);

    // Another actor's turn is the boundary that drains the retired box.
    var keep_freed = false;
    const keeper = try vat.spawn(Probe, .{ .freed = &keep_freed });
    _ = try vat.near(keeper, .{ .verb = "ping" });
    try std.testing.expect(freed);
}

test "a retiring actor destructor drains a sibling it releases at the same boundary" {
    var vat = actors.Vat.init(std.testing.allocator);
    defer vat.deinit();

    var sibling_freed = false;
    const sibling = try vat.spawn(Probe, .{ .freed = &sibling_freed });
    var releaser_freed = false;
    const releaser = try vat.spawn(SiblingReleaser, .{
        .vat = &vat,
        .sibling = sibling,
        .freed = &releaser_freed,
    });
    vat.releaseActor(releaser.local);

    var keeper_freed = false;
    const keeper = try vat.spawn(Probe, .{ .freed = &keeper_freed });
    _ = try vat.near(keeper, .{ .verb = "ping" });
    try std.testing.expect(releaser_freed);
    try std.testing.expect(sibling_freed);
    try std.testing.expect(!vat.hasActor(sibling.local));
    try std.testing.expectEqual(@as(usize, 0), vat.retired_boxes.items.len);
}

test "last-root release consumes registration escrow with allocation refused" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var vat = actors.Vat.init(failing.allocator());
    defer vat.deinit();

    var freed = false;
    var keeper_freed = false;
    const probe = try vat.spawn(Probe, .{ .freed = &freed });
    const keeper = try vat.spawn(Probe, .{ .freed = &keeper_freed });

    // Refuse the next allocation across both the last-root release and the
    // boundary that reclaims its box. Registration already escrowed the slot,
    // so neither lifetime operation asks the allocator or loses the actor.
    const allocations_before = failing.alloc_index;
    failing.fail_index = allocations_before;
    vat.releaseActor(probe.local);
    try std.testing.expect(!vat.hasActor(probe.local));
    try std.testing.expect(!freed);
    _ = try vat.near(keeper, .{ .verb = "ping" });
    try std.testing.expect(freed);
    try std.testing.expectEqual(allocations_before, failing.alloc_index);
    try std.testing.expect(!failing.has_induced_failure);

    failing.fail_index = std.math.maxInt(usize);
}

test "actor registration reports retirement-escrow refusal before commit" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var vat = actors.Vat.init(failing.allocator());
    defer vat.deinit();

    var freed = false;
    // `makeBox` takes the first allocation. Refuse the retirement escrow that
    // follows it: spawn must report the exact OOM, reclaim the adopted state,
    // and leave no actor row visible.
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, vat.spawn(Probe, .{ .freed = &freed }));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(freed);
    try std.testing.expectEqual(@as(usize, 0), vat.actors.count());
    try std.testing.expectEqual(@as(usize, 0), vat.retired_boxes.capacity);

    failing.fail_index = std.math.maxInt(usize);
}

test "retired-box burst trim refuses transactionally and retries exactly" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var vat = actors.Vat.init(failing.allocator());
    defer vat.deinit();

    var keeper_freed = false;
    const keeper = try vat.spawn(Probe, .{ .freed = &keeper_freed });
    var retired_freed = false;
    const burst = actors.steady_list_bytes / @sizeOf(*anyopaque) + 32;
    for (0..burst) |_| {
        const actor = try vat.spawn(Probe, .{ .freed = &retired_freed });
        vat.releaseActor(actor.local);
    }
    try std.testing.expectEqual(burst, vat.retired_boxes.items.len);
    try std.testing.expect(vat.retired_boxes.capacity * @sizeOf(*anyopaque) > actors.steady_list_bytes);
    try std.testing.expect(!retired_freed);

    // The next outer turn first prepares a right-sized retirement reservation.
    // Its refusal must preserve the entire old boundary: no box is released,
    // no frame opens, and an unchanged retry remains possible.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, vat.near(keeper, .{ .verb = "ping" }));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(u32, 0), vat.turn_depth);
    try std.testing.expectEqual(burst, vat.retired_boxes.items.len);
    try std.testing.expect(!retired_freed);

    failing.fail_index = std.math.maxInt(usize);
    _ = try vat.near(keeper, .{ .verb = "ping" });
    try std.testing.expect(retired_freed);
    try std.testing.expectEqual(@as(usize, 0), vat.retired_boxes.items.len);
    try std.testing.expect(vat.retired_boxes.capacity * @sizeOf(*anyopaque) <= actors.steady_list_bytes);
}

test "retain and release on an absent row are tolerated no-ops" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    vat.retainActor(999);
    vat.releaseActor(999);
}

/// Releases its own last root mid-turn, then answers from live state: the
/// deferral in `finishCellRun` is what this exercises.
const SelfReleaser = struct {
    freed: *bool,
    note: [24]u8 = "still alive at turn end.".*,

    pub fn handle(self: *SelfReleaser, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = msg;
        turn.vat.releaseActor(turn.self_id);
        // The reply borrows this box; the retire must wait for the unwind and
        // the box free for the boundary, or this dangles.
        return .{ .string = try turn.arena.dupe(u8, &self.note) };
    }

    pub fn deinit(self: *SelfReleaser, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.freed.* = true;
    }
};

test "a handler releasing its own last root finishes its turn on live state" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    var freed = false;
    const actor = try vat.spawn(SelfReleaser, .{ .freed = &freed });
    const reply = try vat.near(actor, .{ .verb = "bye" });
    try std.testing.expectEqualStrings("still alive at turn end.", reply.string);
    try std.testing.expect(!vat.hasActor(actor.local));

    var keep_freed = false;
    const keeper = try vat.spawn(Probe, .{ .freed = &keep_freed });
    _ = try vat.near(keeper, .{ .verb = "ping" });
    try std.testing.expect(freed);
}

test "a queued turn whose target was reclaimed takes the typed NoSuchActor refusal" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    var freed = false;
    const probe = try vat.spawn(Probe, .{ .freed = &freed });
    const vow = try vat.send(probe, .{ .verb = "ping" });
    var broke = false;
    try vat.on(vow, .{ .ctx = &broke, .func = promise_capture.captureBroken });

    // The queued turn holds no root (ADR-0014): the release wins the race and
    // the drained turn breaks typed instead of reaching freed state.
    vat.releaseActor(probe.local);
    try vat.drive();
    try std.testing.expect(broke);
}

test "restore intersects: a reclaimed actor is not resurrected" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();

    var kept_freed = false;
    var dropped_freed = false;
    const kept = try vat.spawn(Probe, .{ .freed = &kept_freed });
    const dropped = try vat.spawn(Probe, .{ .freed = &dropped_freed });

    var snap = try vat.snapshot();
    defer snap.deinit();

    vat.releaseActor(dropped.local);
    try std.testing.expect(!vat.hasActor(dropped.local));

    // Roots are authority and are never rewound: the surviving row takes the
    // snapshot state, the reclaimed row stays gone.
    try vat.restore(&snap);
    try std.testing.expect(vat.hasActor(kept.local));
    try std.testing.expect(!vat.hasActor(dropped.local));
    _ = try vat.near(kept, .{ .verb = "ping" });
}
