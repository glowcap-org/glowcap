//! Vat footprint budget — the actor layer's half of the burst-drain contract.
//!
//! The standard Host owns one Vat shared by its session Ports. One chatty
//! ingress must not pin its peak queue capacity for the Vat's life. Queue
//! messages therefore live in
//! independently reclaimable chunks. Empty ingresses retain no chunk and the
//! Vat retains at most one bounded spare, while its turn and settlement arenas
//! keep their existing bounded-reset posture. The exact bounds are recorded in
//! .agents/rules/memory.md and mirror the engine queue budget.
//!
//! This test runs one oversized turn (arena scratch far past the bound) and
//! one deep send episode (queue chunks far past the bound), drives to
//! quiescence, and asserts the retained capacities are back under the bounds.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const Turn = actors.Turn;
const Message = actors.Message;

/// Scratch well past the steady bound in one turn, and burst well past it in
/// one send episode.
const oversized_scratch_bytes: usize = 32 * 1024;
const burst_sends: usize = 600;

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

    // One deep send episode: fixed-row chunks and their payload arenas grow
    // past one steady chunk, then drain to quiescence.
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

    // Quiescent: every completed chunk was reclaimed. Burst capacity above the
    // bounds is freed and only the one steady spare is retained.
    try std.testing.expect(vat.spare_chunk != null);
    const spare = vat.spare_chunk.?;
    // One Vat-wide spare replaces the old queue list and monolithic arena. Its
    // fixed row array stays within one steady-list page plus a small header, and
    // its payload arena retains at most the declared Vat-wide spare bound. No
    // idle ingress keeps a separate chunk.
    try std.testing.expect(@sizeOf(@TypeOf(spare.*)) <= actors.steady_list_bytes + 128);
    try std.testing.expect(spare.arena.queryCapacity() <= actors.steady_spare_arena_bytes);

    // The turn arena resets when the *next* outermost turn begins, so open
    // one small turn and assert the oversized episode's capacity is gone.
    _ = try vat.near(actor, .{ .verb = "noop" });
    try std.testing.expect(vat.turn_arena.queryCapacity() <= actors.steady_turn_arena_bytes);
}

test "a burst of actor retirements releases excess capacity at the next turn" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    const keeper = try vat.spawn(BurstActor, .{});

    // Registration escrows one retired-box slot per live actor. Releasing each
    // temporary actor consumes that slot and parks its box until a turn opens,
    // building a real burst well above the retained-list budget.
    for (0..burst_sends) |_| {
        const actor = try vat.spawn(BurstActor, .{});
        vat.releaseActor(actor.local);
    }
    try std.testing.expectEqual(burst_sends, vat.retired_boxes.items.len);
    try std.testing.expect(vat.retired_boxes.capacity * @sizeOf(*anyopaque) > actors.steady_list_bytes);

    // The next outermost turn prepares a right-sized replacement before it
    // drops the retired references, then commits both lifetime changes. The
    // one keeper actor retains one escrow slot; burst capacity returns.
    _ = try vat.near(keeper, .{ .verb = "noop" });
    const retired_bytes = vat.retired_boxes.capacity * @sizeOf(*anyopaque);
    try std.testing.expect(retired_bytes <= actors.steady_list_bytes);
}
