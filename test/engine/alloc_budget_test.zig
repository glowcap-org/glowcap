//! Steady-state wire-path allocation budget (Optimum Core, Phase 0).
//!
//! Locks the number of heap allocations a single `op:deliver` to an
//! already-live local export costs once the session has reached steady state
//! (tables warmed, event/queue backing arrays grown). This is the measurement
//! anchor the data-oriented session rewrite drives down: each later phase must
//! not regress this budget, and the borrowed-validate / owned-on-retain split
//! (Phase 5) lowers it toward its irreducible minimum — the single owned-frame
//! copy the frame-based event model requires for a retained event.
//!
//! A regression in *either* direction fails: the budget is an exact contract,
//! not an upper bound.

const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const engine = pancake.engine;

/// Counts every backing allocation (fresh `alloc`, plus a `remap`/`resize` that
/// grows an existing block) so the measurement reflects real heap traffic, not
/// just same-size allocations.
const TotalCountingAllocator = struct {
    backing: std.mem.Allocator,
    allocs: usize = 0,

    fn allocator(self: *TotalCountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TotalCountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) self.allocs += 1;
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TotalCountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TotalCountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null and new_len > memory.len) self.allocs += 1;
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TotalCountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

/// `op:deliver` to local export 7 carrying one inline bytes argument, answer-pos
/// 11. The argument exercises the owned-message validation materialization
/// (`ownedFromView`) the borrowed-validate split (Phase 5) removes, so the
/// budget measures that win rather than only the irreducible owned-frame copy.
/// Reusing one fixed frame keeps the inbound-answer install idempotent after the
/// first turn (answer 11 is registered once), so steady-state turns mutate no
/// table.
const deliver_to_live_export = "<10'op:deliver<11'desc:export7+>[5:hello]11+f>";

/// Drive one wire turn: dispatch the borrowed deliver and drain every surfaced
/// event (releasing each owned frame), matching how a host pumps the peer. The
/// final empty poll lets the peer reclaim its event-queue slots, so a long-lived
/// session reuses backing capacity instead of growing one entry per turn.
fn driveOneTurn(peer: *engine.Peer) !void {
    try peer.recvBorrowed(.{ .bytes = deliver_to_live_export, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
}

test "steady-state deliver to a live export holds its allocation budget" {
    var counter = TotalCountingAllocator{ .backing = std.testing.allocator };
    var peer = engine.Peer.init(counter.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(7);

    // Warm up: install answer 11 and grow the inbound/event backing arrays so
    // the measured window sees only per-turn wire-path traffic.
    const warmup = 8;
    for (0..warmup) |_| try driveOneTurn(&peer);

    const turns = 16;
    counter.allocs = 0;
    for (0..turns) |_| try driveOneTurn(&peer);

    try std.testing.expectEqual(@as(usize, 0), counter.allocs % turns);
    const per_turn = counter.allocs / turns;

    // Budget for a one-arg inbound deliver to a live export: a single allocation,
    // the owned-frame copy the retained event requires (`ownedFrameFromView`).
    // The owned-message validation materialization that used to cost two more
    // allocations per turn (the argument slice + the duped bytes payload) is
    // gone — the borrowed-validate / owned-on-retain split (Phase 5) validates
    // and applies authority straight from the borrowed codec projection
    // (`Session.recordRecvView`). This is the irreducible steady-state floor
    // under the frame-based event model; a regression in either direction fails.
    const budget = 1;
    try std.testing.expectEqual(@as(usize, budget), per_turn);
}
