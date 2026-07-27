//! Vat footprint budget — the actor layer's half of the burst-drain contract.
//!
//! At the multi-session CapTP tier a vat is minted per accepted session
//! (`driver.core.Host` via `driver.Bridge`), so vat-retained heap is
//! per-session heap: one
//! chatty burst must not pin its peak capacity for the session's life, the
//! exact hole the engine's queues already close (`Queue.steady_queue_bytes`,
//! held by test/engine/footprint_budget_test.zig). The vat holds the same
//! posture with four declared steady bounds (`src/actors/vat.zig`, recorded in
//! .agents/rules/memory.md's per-session footprint budget): the three arenas
//! reset with `retain_with_limit` at their existing boundaries, and the
//! `queue` / `moved_replies` lists `clearAndFree` above the bound at their
//! drain points. The named price is one growth re-allocation at the start of
//! the next burst episode, never per turn.
//!
//! This test runs one oversized turn (arena scratch far past the bound) and
//! one deep send episode (queue and queue arena far past the bound), drives to
//! quiescence, and asserts the retained capacities are back under the bounds.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const Turn = actors.Turn;
const Message = actors.Message;

/// The declared steady bounds this test holds, mirrored from the vat's
/// private constants (`steady_turn_arena_bytes`, `steady_queue_arena_bytes`,
/// `steady_list_bytes`, all 4096). A drift between these literals and the
/// vat's fails this test, which is the point: raising the bound is a design
/// event taken in both places, with memory.md updated alongside.
const steady_bytes: usize = 4096;

/// Scratch well past the steady bound in one turn, and burst well past it in
/// one send episode.
const oversized_scratch_bytes: usize = 32 * 1024;
const burst_sends: usize = 600;

/// A persistent actor whose every turn installs a fresh state box, so a burst
/// of turns leaves a burst of retired boxes waiting for the next outermost
/// turn to release them.
const BecomeBurstActor = struct {
    pub const snapshot_persistent = true;
    turns: usize = 0,

    pub fn handle(self: *const BecomeBurstActor, turn: *Turn, msg: Message) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "step")) {
            try turn.become(BecomeBurstActor, .{ .turns = self.turns + 1 });
            return .{ .void = {} };
        }
        if (std.mem.eql(u8, msg.verb, "turns")) return .{ .integer = @intCast(self.turns) };
        return error.NoSuchMethod;
    }
};

const BurstActor = struct {
    turns: usize = 0,

    pub fn handle(self: *BurstActor, turn: *Turn, msg: Message) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "oversized")) {
            const scratch = try turn.arena.alloc(u8, oversized_scratch_bytes);
            @memset(scratch, 0xaa);
            return .{ .void = {} };
        }
        if (std.mem.eql(u8, msg.verb, "note")) {
            self.turns += 1;
            return .{ .void = {} };
        }
        if (std.mem.eql(u8, msg.verb, "turns")) return .{ .integer = @intCast(self.turns) };
        if (std.mem.eql(u8, msg.verb, "noop")) return .{ .void = {} };
        return error.NoSuchMethod;
    }
};

test "a burst-drained vat releases its burst capacity back under the steady bounds" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    const actor = try vat.spawn(BurstActor, .{});

    // One oversized turn: the handler bumps 32 KiB of turn-arena scratch.
    _ = try vat.near(actor, .{ .verb = "oversized" });

    // One deep send episode: the queue list and the queue arena (verb + args
    // clones) both grow far past the steady bound, then drain to quiescence.
    const payload = [_]u8{'x'} ** 64;
    for (0..burst_sends) |_| {
        try vat.tell(actor, .{ .verb = "note", .args = &.{.{ .bytes = &payload }} });
    }
    try vat.drive();
    // Every queued turn really ran.
    try std.testing.expectEqual(
        @as(i64, @intCast(burst_sends)),
        (try vat.near(actor, .{ .verb = "turns" })).integer,
    );

    // Quiescent: the outermost drive's full-drain reset ran. Burst capacity
    // above the bounds is freed, steady capacity retained.
    const queued_bytes = vat.queue.capacity * @sizeOf(@TypeOf(vat.queue.items[0]));
    try std.testing.expect(queued_bytes <= steady_bytes);
    try std.testing.expect(vat.queue_arena.queryCapacity() <= steady_bytes);

    // The turn arena resets when the *next* outermost turn begins, so open
    // one small turn and assert the oversized episode's capacity is gone.
    _ = try vat.near(actor, .{ .verb = "noop" });
    try std.testing.expect(vat.turn_arena.queryCapacity() <= steady_bytes);
}

test "a burst of becomes releases its retired-box capacity back under the steady bound" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    const actor = try vat.spawn(BecomeBurstActor, .{});

    // Each queued turn installs a become, and every outgoing box is held until
    // the next outermost turn rather than freed at the install, because a reply
    // from an earlier frame can still borrow it. So one drive episode parks one
    // box per turn.
    for (0..burst_sends) |_| {
        try vat.tell(actor, .{ .verb = "step", .args = &.{} });
    }
    try vat.drive();
    try std.testing.expectEqual(
        @as(i64, @intCast(burst_sends)),
        (try vat.near(actor, .{ .verb = "turns" })).integer,
    );

    // The `near` above was an outermost turn, so the burst has drained and its
    // capacity above the bound is returned. The testing allocator is the other
    // half of the verdict: a retired box that never released would leak here.
    const retired_bytes = vat.retired_boxes.capacity * @sizeOf(*anyopaque);
    try std.testing.expect(retired_bytes <= steady_bytes);
}
