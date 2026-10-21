//! The drive side of the lifecycle-accounting target in
//! `test/net/fuzz_test.zig`: the serve hooks, the per-run drive that reads one
//! drawn schedule through `backend.LifecycleBackend`, and the exact-accounting
//! oracle the run must satisfy once quiescent.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const net = glowcap.net;
const engine = glowcap.ocapn.engine;
const completion = net.completion;

const backend = @import("lifecycle_backend.zig");
const LifecycleBackend = backend.LifecycleBackend;
const DialAnything = backend.DialAnything;
const buildHello = backend.buildHello;
const max_steps = backend.max_steps;
const max_batch = backend.max_batch;
const max_slots = backend.max_slots;
const frame_cap = @import("bounds.zig").frame_cap;
const handshake = @import("../../support/handshake.zig");

fn makeLifecyclePeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    _ = ctx;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
    errdefer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    // Whether a connection opens with outbound already queued is a schedule
    // choice, and it decides whether the loop's central mechanism is exercised
    // at all. Without a queued frame an open connection's `pendingOut` is zero
    // for its whole life, so it can never cross the outbound high-water mark,
    // so the ADR-0017 sink park never fires, and neither does anything behind
    // it: the single-connection un-park, the park deadline, the park-to-drain
    // restamp. Measured over four thousand schedules, all of those ran zero
    // times before this line and thousands of times after.
    //
    // Conditional rather than always, because always is worse in the other
    // direction: a peer with something to flush never reaches `teardown`
    // inline from `failConn`, which is the path the adoption-teardown deferral
    // needs, and that dropped to zero when it was unconditional.
    if (backend.schedule.len > 0 and backend.schedule[0] & 2 != 0) {
        try peer.sendBorrowed(handshake.startSession(net.tcp.plain.transport_name, "fuzz"));
    }
    return peer;
}

/// The generation each slot carried the last time it was adopted, and whether
/// it has been adopted at all.
var last_generation: [max_slots]u32 = @splat(0);
var slot_used: [max_slots]bool = @splat(false);
/// Set when a slot was re-adopted carrying a generation it had already used.
var generation_repeated = false;

/// Adopting a slot is where its identity has to advance. A connection's slot
/// number is reused. The generation is what tells a holder of a stale reference
/// that the slot became somebody else's, and the loop's own bridge relies on
/// that to route a flush to the right connection. Checked at adoption because
/// that is the moment the previous occupant's identity must already be spent.
///
/// The hook also condemns and fails, on the schedule's say-so, because this is
/// the one moment a slot can be torn down while it is being adopted. A real
/// bridge condemns from right here, it drains its host's actions inside this
/// hook, and one of them can be a close, and the loop answers by deferring
/// the teardown until the hook returns. A hook that only ever reads and
/// returns null leaves that whole deferral unreachable, so the header's claim
/// to drive "a teardown while a slot is being adopted" would be a claim about
/// code no input can run.
fn watchAdoption(ctx: ?*anyopaque, peer: *engine.Peer, slot: usize) anyerror!?*anyopaque {
    const loop: *completion.Loop(LifecycleBackend, DialAnything) = @ptrCast(@alignCast(ctx.?));
    _ = peer;
    const generation = loop.conns[slot].generation;
    if (slot_used[slot] and generation == last_generation[slot]) generation_repeated = true;
    slot_used[slot] = true;
    last_generation[slot] = generation;

    const decision = loop.backend.draw();
    if (decision % 8 == 1) loop.closeSlot(slot);
    // And sometimes a *different* slot. `armOutbound` and `closeSlot` are the
    // loop's public re-entry surface, and a real bridge reaches them from here
    // by draining its host's actions, one of which can close some other
    // connection entirely. Closing only this slot exercises the deferral and
    // nothing else; closing a sibling is what walks a list the caller above is
    // in the middle of.
    const other = (slot + 1 + @as(usize, decision % max_slots)) % max_slots;
    if (decision % 5 == 2 and other != slot) loop.closeSlot(other);
    // Drawn from a different residue than the condemn above, which is `% 8 == 1`:
    // `7 % 8` is 7, so `% 16 == 7` could never coincide with it, and the arm
    // where a slot is condemned *and* the hook then fails, the one that defers
    // a teardown across an adoption error, was arithmetically unreachable.
    if (decision % 8 == 1 and decision % 3 == 1) return error.AdoptionRefused;
    if (decision % 16 == 7) return error.AdoptionRefused;
    // A real context, so `free_conn_ctx` has something to free, including on
    // the arm where the slot was condemned while this hook ran, which releases
    // the context before tearing the peer down.
    return makeConnCtx();
}

/// A per-connection context, so `free_conn_ctx` has something to free and the
/// condemned-while-adopting release runs. One byte on the gpa, freed by the
/// hook below or leaked loudly by the testing allocator if the loop forgets.
var ctx_allocator: ?std.mem.Allocator = null;
var contexts_built: usize = 0;
var contexts_seen_on_close: usize = 0;
var contexts_freed: usize = 0;

fn makeConnCtx() ?*anyopaque {
    const a = ctx_allocator orelse return null;
    const cell = a.create(u8) catch return null;
    cell.* = 1;
    contexts_built += 1;
    return @ptrCast(cell);
}

fn freeConnCtx(ctx: ?*anyopaque, conn_ctx: ?*anyopaque) void {
    _ = ctx;
    const a = ctx_allocator orelse return;
    const cell: *u8 = @ptrCast(@alignCast(conn_ctx orelse return));
    contexts_freed += 1;
    a.destroy(cell);
}

/// The serve hook, which the loop calls for every surfaced event. Refusing on
/// the schedule's say-so reaches `onRecvFinish`'s hook-error arm, which closes
/// the connection rather than the loop.
fn serveEvent(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
    _ = .{ conn_ctx, peer, event };
    if (serve_backend) |b| {
        if (b.draw() % 16 == 9) return error.ServeRefused;
    }
}

/// The park hook. It fires from inside `markParked`, after the state is
/// settled, and it is public, so what it does here is what a real embedder
/// may do: reach back into the loop.
fn onParked(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, reason: completion.ParkReason) void {
    _ = .{ conn_ctx, reason };
    const loop: *completion.Loop(LifecycleBackend, DialAnything) = @ptrCast(@alignCast(ctx orelse return));
    const decision = loop.backend.draw();
    if (decision % 10 == 6) loop.closeSlot(slot);
    // The loop names `armOutbound` and `closeSlot` together as its public
    // re-entry surface, and only `closeSlot` was ever called from a hook. This
    // is the other one: a bridge flushes a sibling's queue from here, which is
    // what pushes a connection over the outbound mark while its own recv is
    // still armed.
    if (decision % 9 == 5) {
        for (loop.conns, 0..) |*other, other_slot| {
            if (other_slot == slot or other.state != .open) continue;
            loop.armOutbound(other_slot);
            break;
        }
    }
    // And sometimes a sibling, which is the case worth reaching: a parked slot
    // has no armed recv and nothing in flight, so condemning it goes straight
    // to closed. A sibling is mid-conversation, so condemning it lands on
    // `.draining` with a recv still armed and bytes still queued, which is
    // where `onRecvConsume`'s draining arm and `onSend`'s terminal back-swap
    // live, and neither had ever run.
    if (decision % 7 == 4) {
        // A slot that is actually mid-conversation, not an arbitrary index.
        // With four slots and usually one or two live, picking blind mostly
        // picked a free slot and closed nothing.
        for (loop.conns, 0..) |*other, other_slot| {
            // Specifically one with a recv already armed. That is the race the
            // loop's `.draining` recv arm exists for, a terminal failure
            // arriving on a connection that is waiting to read, and picking
            // any open slot mostly picked the one being dispatched, whose seat
            // is idle, so the arm never ran.
            if (other_slot == slot or other.state != .open or other.read != .armed) continue;
            // And with a write still outstanding, so the terminal flush has
            // something to wait on. Without that, condemning it finds nothing
            // to send and goes straight to closing, where a late recv is
            // dropped by the liveness guard instead of reaching the draining
            // arm this is trying to exercise.
            if (!other.write_in_flight) continue;
            loop.closeSlot(other_slot);
            break;
        }
    }
}

/// The backend the serve hook draws from. File scope because the hook's
/// signature carries the connection context, not the loop.
var serve_backend: ?*LifecycleBackend = null;

/// Fires once per connection the loop actually reclaims, which makes it an
/// independent count of the thing `closed_count` claims to hold. Derived
/// counters compared against a walk of the state they summarize cannot see a
/// count incremented twice for one connection. A second, separately-sourced
/// tally can.
var close_hook_fires: usize = 0;

fn countClose(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, report: completion.CloseReport) void {
    _ = .{ ctx, slot, report };
    if (conn_ctx != null) contexts_seen_on_close += 1;
    close_hook_fires += 1;
}

pub fn driveLifecycle(_: void, smith: *std.testing.Smith) anyerror!void {
    const allocator = std.testing.allocator;
    backend.schedule = backend.schedule_buf[0..smith.slice(&backend.schedule_buf)];
    defer backend.schedule = &.{};
    // A schedule too short to accept a connection cannot reach anything worth
    // asserting, and a run that ends there is a run the search wasted. The
    // first byte configures the loop, so the backend reads decisions from the
    // rest.
    if (backend.schedule.len < 8) return;

    var loop = completion.Loop(LifecycleBackend, DialAnything).initWithBackendOptions(
        allocator,
        .{ .read_buffers = 2 },
        makeLifecyclePeer,
        null,
        .{
            .max_conns = max_slots,
            .listen = 0,
            // Small enough that an ordinary short write puts a connection over
            // it, so the fan-in accounting is actually reached.
            .outbound_high_water_bytes = 48,
            // The throttle is a schedule choice, not a constant. With it on,
            // the fan-in release sweep is what un-parks a connection, and the
            // one-connection un-park in `resumeIfDrained` is unreachable,
            // measured: zero times in four hundred runs. That branch is the
            // whole un-park path when the throttle is off, so pinning the
            // option pinned half the code out of the search.
            .fan_in_throttle = backend.schedule[0] % 2 == 0,
            // Both reapers armed and short, so the deadline sweeps run rather
            // than being dead code under the fuzzer.
            .park_kill_ms = 1,
            .drain_kill_ms = 1,
            .make_conn_ctx = watchAdoption,
            .free_conn_ctx = freeConnCtx,
            .serve = serveEvent,
            .on_park = onParked,
            .on_close = countClose,
        },
    ) catch return;
    // The adoption hook reads the loop it is called from, and the loop is what
    // it is passed as the shared context.
    loop.make_ctx = &loop;
    ctx_allocator = allocator;
    serve_backend = &loop.backend;
    buildHello(allocator);
    defer {
        ctx_allocator = null;
        serve_backend = null;
    }
    last_generation = @splat(0);
    slot_used = @splat(false);
    generation_repeated = false;
    close_hook_fires = 0;
    contexts_built = 0;
    contexts_seen_on_close = 0;
    contexts_freed = 0;
    var deinited = false;
    defer if (!deinited) {
        loop.backend.draining = true;
        loop.closeAndDrain() catch {};
        loop.deinit();
    };

    // Dial before running, on the schedule's say-so. Without a dial the loop's
    // outbound half, the connect completion, the late fd assignment, a refused
    // dial's `opened == false` teardown, slot exhaustion, has no input that
    // reaches it.
    var dials: usize = 0;
    while (dials < max_slots and backend.schedule[1] >> @intCast(dials) & 1 != 0) : (dials += 1) {
        _ = loop.dialLocator(.{
            .transport = "fuzz",
            .designator = "peer",
            .hints = model.Hints.emptyFalse(),
        }) catch break;
    }

    loop.run(.forever) catch {};

    try std.testing.expect(!generation_repeated);

    // The live loop, wherever the schedule left it. This is the strongest
    // place to look: connections are still open, still parked, still holding
    // whatever the schedule built, and a count that has drifted has not yet status-allow: pending state or quoted runtime label
    // been washed out by a teardown that resets everything anyway.
    try expectAccountingExact(&loop);
    // `deinit` on a live loop is a call the API allows, and it is the only
    // route to the branch that releases an *open* connection's contributions:
    // every other teardown comes through `closeConn`, which has already
    // cleared them. Its precondition is that nothing is in flight, so take
    // the branch only when that holds, and let the schedule decide when.
    //
    // From the schedule, not a separate `smith.boolWeighted` draw. The draw
    // happens after `smith.slice` has consumed the input, so outside the
    // fuzzer it always returned the same answer, and this branch ran zero
    // times in four hundred runs while looking like a coin flip. Read from a
    // schedule byte it runs about one run in ten, and the part that matters is
    // that a probe can measure which.
    if (backend.schedule[1] % 3 == 0 and quiescent(&loop)) {
        // Its two assertions, every deadline stamp and every over-mark
        // released, are the check here.
        loop.deinit();
        deinited = true;
        try std.testing.expectEqual(contexts_built, contexts_seen_on_close);
        try std.testing.expectEqual(contexts_built, contexts_freed);
        return;
    }

    // Otherwise drain on a backend that refuses nothing, so every
    // outstanding operation retires and teardown is reached from wherever the
    // schedule left the loop.
    loop.backend.draining = true;
    loop.closeAndDrain() catch {};
    try expectAccountingExact(&loop);

    // `closed_count` against a tally taken somewhere else entirely. The walk
    // above compares each count to the state it summarizes, which cannot see a
    // count incremented twice for one connection, both sides move together.
    // The close hook fires once per reclaim, from inside the reclaim, so it is
    // the independent witness that catches exactly that.
    try std.testing.expectEqual(close_hook_fires, loop.closed_count);
    try std.testing.expectEqual(contexts_built, contexts_seen_on_close);
    try std.testing.expectEqual(contexts_built, contexts_freed);
}

/// Whether every live connection has retired its operations, the state
/// `Loop.deinit` requires of a caller that has not drained.
fn quiescent(loop: anytype) bool {
    for (loop.conns) |*c| {
        if (c.state != .free and c.ops_in_flight != 0) return false;
    }
    return true;
}

/// Every derived count against a walk of the slots. These are maintained
/// edge-triggered across dozens of mutation sites, and each drift a review
/// found was one path forgetting to release.
fn expectAccountingExact(loop: anytype) !void {
    var stamped: usize = 0;
    var over: usize = 0;
    var owed: usize = 0;
    var free_slots: usize = 0;
    var live: usize = 0;
    for (loop.conns) |*c| {
        if (c.state != .free) live += 1;
        if (c.waiting_since_ms != 0) stamped += 1;
        if (c.over_mark) over += 1;
        if (c.owns_fd_close) owed += 1;
        if (c.state == .free) {
            free_slots += 1;
            // A reclaimed slot owns nothing. Its reset is what returns the
            // counts, so a field that survives it is a leak into the next
            // connection to take the slot.
            try std.testing.expectEqual(@as(i64, 0), c.waiting_since_ms);
            try std.testing.expect(!c.over_mark);
            try std.testing.expect(!c.owns_fd_close);
            try std.testing.expectEqual(@as(usize, 0), c.ops_in_flight);
        }
        // A closing connection is on its way out and must not be holding the
        // loop's attention. A stamp left behind here is a wake per poll for a
        // connection nothing will ever reap, and an over-mark left behind
        // throttles other connections on behalf of one that is already gone.
        // Both are stated rather than derived: a count compared against a walk
        // of the same field agrees with itself even when both have drifted, so
        // it cannot see a release that was skipped everywhere at once.
        if (c.state == .closing) {
            try std.testing.expectEqual(@as(i64, 0), c.waiting_since_ms);
            try std.testing.expect(!c.over_mark);
        }
    }
    try std.testing.expectEqual(stamped, loop.waiting_count);
    try std.testing.expectEqual(over, loop.over_mark_count);
    try std.testing.expectEqual(owed, loop.pending_close_submits);
    try std.testing.expectEqual(live, loop.live_count);

    // The throttle bounds itself. A connection over the outbound mark parks
    // every other read, so one of them must be carrying the deadline that ends
    // it, otherwise the loop waits on a completion that cannot arrive, which
    // is a hang and not backpressure.
    if (loop.fan_in_throttle and loop.over_mark_count > 0) {
        try std.testing.expect(loop.waiting_count > 0);
    }

    // The two admission-partitioned free lists hold every reclaimed slot
    // exactly once. A slot pushed twice hands one connection to two adopters;
    // one never pushed is capacity the loop can never use again.
    var listed: usize = 0;
    var walk = loop.ordinary_free_head;
    while (walk < loop.conns.len) : (listed += 1) {
        try std.testing.expect(listed <= loop.conns.len);
        try std.testing.expect(walk < loop.ordinary_capacity);
        try std.testing.expect(loop.conns[walk].state == .free);
        walk = loop.conns[walk].next_link;
    }
    walk = loop.reserved_free_head;
    while (walk < loop.conns.len) : (listed += 1) {
        try std.testing.expect(listed <= loop.conns.len);
        try std.testing.expect(walk >= loop.ordinary_capacity);
        try std.testing.expect(loop.conns[walk].state == .free);
        walk = loop.conns[walk].next_link;
    }
    try std.testing.expectEqual(free_slots, listed);

    // The other two lists, walked the same way. All four thread one `next_link`
    // word, and that is valid because their states are disjoint: a free slot's
    // seat is idle, and starved and parked are two values of one enum. Walking
    // each list and checking its member state catches duplicate membership,
    // stale membership, and cycles.
    var starved: usize = 0;
    var s = loop.starved_head;
    while (s < loop.conns.len) : (starved += 1) {
        try std.testing.expect(starved <= loop.conns.len);
        try std.testing.expect(loop.conns[s].state != .free);
        try std.testing.expect(loop.conns[s].read == .starved);
        s = loop.conns[s].next_link;
    }

    var parked: usize = 0;
    var p = loop.parked_head;
    while (p < loop.conns.len) : (parked += 1) {
        try std.testing.expect(parked <= loop.conns.len);
        try std.testing.expect(loop.conns[p].state != .free);
        try std.testing.expect(loop.conns[p].read == .parked);
        p = loop.conns[p].next_link;
    }
    // And every parked or starved connection is on its list. A seat marked but
    // never linked is a connection the resume cannot find: it corrupts
    // nothing, it just strands a reader forever, so only counting the two
    // directions against each other catches it.
    var parked_seats: usize = 0;
    var starved_seats: usize = 0;
    for (loop.conns) |*c| {
        if (c.state == .free) continue;
        if (c.read == .parked) parked_seats += 1;
        if (c.read == .starved) starved_seats += 1;
    }
    try std.testing.expectEqual(parked_seats, parked);
    try std.testing.expectEqual(starved_seats, starved);
}
