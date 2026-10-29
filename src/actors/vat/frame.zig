//! The frame spine: `openTurnFrame`/`closeTurnFrame` around one handler run
//! is the one dispatch path the near-call, the queued call, and the wire
//! deliver share, and the turn and moved-reply arenas reset on its outermost
//! boundaries. Retired actor boxes park here until that boundary.

const std = @import("std");
const model = @import("model");

const boxed = @import("boxed.zig");
const turn_commit = @import("turn_commit.zig");
const vat_mod = @import("mod.zig");

const Turn = vat_mod.Turn;
const Source = Turn.Source;
const Error = vat_mod.Error;
const Vat = vat_mod.Vat;
const StateBox = boxed.StateBox;
const releaseBox = boxed.releaseBox;
const Delivery = vat_mod.Delivery;
const Queued = @import("behavior.zig").Queued;

/// Released rows leave boxes borrowed by the preceding turn. The next outer
/// boundary owns their reclamation. Idle adapters can observe that obligation.
pub fn hasRetiredState(self: *const Vat) bool {
    return self.retired_boxes.items.len != 0;
}

/// Cap on synchronous near-call (`$`) nesting depth. Eventual-sends do not count
/// (they queue and drive iteratively). Only a handler that near-calls another
/// actor that near-calls back recurses the native stack, so this bounds that
/// recursion well below a stack overflow while leaving ample room for the few
/// levels real code nests.
const max_near_call_depth: u32 = 128;

/// Reserve the retired-box slots already-committed lifetime operations will
/// consume without allocation: one for every live actor, plus any actor rows
/// and staged becomes the caller is about to add. `releaseActor`, Port teardown,
/// and frame unwind are infallible. Their capacity is escrowed at
/// the earlier fallible spawn/become seam instead of losing reclamation to OOM. status-allow: event or source ordering
/// The sum is a table count plus at most one row and the bounded frame depth.
pub fn reserveRetirementCapacity(self: *Vat, additional_actors: usize, possible_becomes: usize) Error!void {
    try self.retired_boxes.ensureUnusedCapacity(self.allocator, self.actors.count() + additional_actors + possible_becomes);
}

/// What one turn dispatches to its box: a delivery the handler reads, or an
/// adapter-owned body for a box that accepts one.
const Dispatch = union(enum) {
    delivery: Delivery,
    owned: vat_mod.OpaqueMessage,

    fn fromQueued(msg: Queued) Dispatch {
        return switch (msg) {
            .message => |message| .{ .delivery = message.delivery() },
            .owned => |body| .{ .owned = body },
        };
    }
};

/// Stack-owned completion of one queued call. A deferral transfers settlement
/// to its listener. Diagnostics borrow the turn arena or immutable archive text.
pub const EventualOutcome = union(enum) {
    /// The handler's return decides.
    pending,
    deferred,
    discarded,
    broken: []const u8,
};

pub fn callQueued(self: *Vat, source: Source, id: u64, msg: Queued, answer: ?u64) ?vat_mod.Outcome {
    var outcome: EventualOutcome = .pending;
    const result = callWithOrigin(self, source, id, Dispatch.fromQueued(msg), .{ .eventual = .{ .answer = answer, .outcome = &outcome } });
    return switch (outcome) {
        .pending => if (result) |value| .{ .fulfilled = value } else |err| .{ .broken = @errorName(err) },
        .deferred => null,
        .discarded => .{ .fulfilled = .{ .void = {} } },
        .broken => |reason| .{ .broken = reason },
    };
}

/// Free every reply a handler moved to the vat and not yet reclaimed. Called status-allow: pending state or quoted runtime label
/// when an outermost turn begins (mirroring the turn arena's reset) and at
/// teardown, so a moved reply lives exactly as long as a borrowed one would.
pub fn drainMovedReplies(self: *Vat) void {
    for (self.moved_replies.items) |bytes| self.allocator.free(bytes);
    self.moved_replies.clearRetainingCapacity();
    if (self.moved_replies.capacity * @sizeOf([]const u8) > vat_mod.steady_list_bytes) {
        self.moved_replies.clearAndFree(self.allocator);
    }
}

/// Release resources before their borrowed storage is invalidated. Detaching
/// each node before its destructor also makes terminal cleanup idempotent.
pub fn drainTurnResources(self: *Vat) void {
    while (self.turn_resources) |resource| {
        self.turn_resources = resource.next;
        resource.destroy(resource);
    }
}

/// Retired actor destructors may open nested calls and register reply custody.
/// Drain both owners to quiescence before resetting their shared arena.
pub fn reclaimTurnStorage(self: *Vat) void {
    while (true) {
        drainTurnResources(self);
        releaseRetiredBoxes(self);
        if (self.turn_resources == null) return;
    }
}

/// What an outermost turn's opening commits: prepared before the frame is
/// marked running, so the reset itself cannot fail.
const TurnBoundary = struct {
    outermost: bool,
    /// A right-sized replacement prepared before the boundary commits. This
    /// makes burst trimming exact and fallible without discarding any prior
    /// turn lifetime when its allocation is refused.
    retired_replacement: ?std.ArrayList(*StateBox) = null,

    fn deinit(self: *TurnBoundary, allocator: std.mem.Allocator) void {
        if (self.retired_replacement) |*replacement| replacement.deinit(allocator);
        self.* = undefined;
    }
};

fn prepareTurnBoundary(self: *Vat) Error!TurnBoundary {
    if (self.turn_depth != 0) return .{ .outermost = false };

    const live_actor_slots = self.actors.count();
    const burst_sized = self.retired_boxes.capacity > vat_mod.steady_list_bytes / @sizeOf(*StateBox);
    if (!burst_sized or self.retired_boxes.capacity <= live_actor_slots) {
        return .{ .outermost = true };
    }

    var replacement: std.ArrayList(*StateBox) = .empty;
    errdefer replacement.deinit(self.allocator);
    try replacement.ensureTotalCapacityPrecise(self.allocator, live_actor_slots);
    return .{ .outermost = true, .retired_replacement = replacement };
}

/// Open a top-level or nested turn and hand back its scratch allocator. The
/// arena is reset only when an *outermost* turn opens (depth was 0), so a turn
/// keeps its scratch live across any near-calls and sends it makes, and the
/// previous outermost turn's reply stays valid until the next one begins.
fn beginTurn(self: *Vat, boundary: *TurnBoundary) std.mem.Allocator {
    // Destructors are application code too. Establish the execution boundary
    // before reclaiming retired state, so adapters cannot re-drive this Vat.
    self.turn_depth += 1;
    if (boundary.outermost) {
        // Every allocation the boundary needs succeeded in prepareTurnBoundary,
        // so the lifetime transition below is one infallible commit.
        reclaimTurnStorage(self);
        if (boundary.retired_replacement) |replacement| {
            self.retired_boxes.deinit(self.allocator);
            self.retired_boxes = replacement;
            boundary.retired_replacement = null;
        }
        // This outermost turn invalidates its predecessor's borrowed scratch.
        // The reset keeps a bounded amount of memory, so steady traffic
        // allocates nothing and one large turn cannot pin its peak.
        _ = self.turn_arena.reset(.{ .retain_with_limit = vat_mod.steady_turn_arena_bytes });
        // Moved replies share the arena's lifetime, so reclaim the previous
        // outermost turn's moved bytes at the same boundary its scratch
        // resets. A borrowed reply from the last turn is now invalid too.
        drainMovedReplies(self);
    }
    return self.turn_arena.allocator();
}

fn endTurn(self: *Vat) void {
    self.turn_depth -= 1;
    if (self.turn_depth != 0) return;
    // A successful outermost turn committed its sends inside its frame; a
    // failed one drops them now, with listeners running at depth zero.
    if (self.turn_failure) |reason| {
        self.turn_failure = null;
        turn_commit.drop(self, reason);
    }
    std.debug.assert(self.staged.items.len == 0);
    std.debug.assert(self.participants.items.len == 0);
}

/// One open turn frame: the actor's state box, the turn arena, and the
/// actor id whose run count the close decrements.
const TurnFrame = struct { box: *StateBox, arena: std.mem.Allocator, id: u64 };

/// The one turn-open spine both dispatch paths (`callLocal`,
/// `serveDeliver`) run: bound the near-call depth, refuse a missing actor,
/// copy-on-write a snapshot-shared box, mark the frame running, and open
/// the turn arena, in exactly that order, because a refusal must happen
/// before the arena resets or the frame is marked running, so a refused
/// dispatch leaves the vat untouched. The box pointer is read out before
/// the handler runs: a handler may spawn, which can resize `actors` and
/// invalidate the cell pointer. Close with `defer closeTurnFrame(id)`.
pub fn openTurnFrame(self: *Vat, id: u64) Error!TurnFrame {
    // Bound the near-call recursion before it can overflow the native
    // stack: each nested `$` deepens `turn_depth`, so refuse once it would
    // exceed the cap rather than crashing on a cyclic local graph.
    if (self.turn_depth >= max_near_call_depth) return error.NearCallTooDeep;
    const cell = self.actors.getPtr(id) orelse return error.NoSuchActor;
    var boundary = try prepareTurnBoundary(self);
    errdefer boundary.deinit(self.allocator);
    try boxed.ensureUnshared(self, cell);
    const box = cell.box;
    cell.running += 1;
    // beginTurn runs destructors, which can spawn or release actors. Commit
    // the running hold before that effect and never reuse the borrowed cell.
    const arena = beginTurn(self, &boundary);
    return .{ .box = box, .arena = arena, .id = id };
}

/// Unwind an open turn frame: install any promoted `become` only when this
/// actor's outermost frame unwinds (so a reentrant inner become never
/// frees the box an outer frame is still running as `self`), then close
/// the turn, `finishCellRun` before `endTurn`, the order the two paths'
/// paired defers always ran in.
pub fn closeTurnFrame(self: *Vat, id: u64) void {
    finishCellRun(self, id);
    endTurn(self);
}

/// Close a frame whose handler returned: promote its staged become, then,
/// at the outermost frame, commit the turn's staged sends and participants
/// before the reply leaves (ADR-0058).
pub fn commitFrame(self: *Vat, turn: *Turn) void {
    if (turn.pending_become) |box| boxed.promoteBecome(self, turn.self_id, box);
    if (self.turn_depth == 1) turn_commit.commit(self);
}

/// Close a frame whose handler failed: release its staged become, and at the
/// outermost frame record `reason` so the turn's effects drop when it closes.
pub fn failFrame(self: *Vat, turn: *Turn, reason: []const u8) void {
    if (turn.pending_become) |box| releaseBox(self.allocator, box);
    if (self.turn_depth == 1) self.turn_failure = reason;
}

pub fn callLocal(self: *Vat, source: Source, id: u64, msg: Delivery) anyerror!model.Argument {
    return callWithOrigin(self, source, id, .{ .delivery = msg }, .local);
}

fn callWithOrigin(self: *Vat, source: Source, id: u64, msg: Dispatch, origin: @FieldType(Turn, "origin")) anyerror!model.Argument {
    const opened = try openTurnFrame(self, id);
    const box = opened.box;
    const arena = opened.arena;
    defer closeTurnFrame(self, id);
    var turn = Turn{ .vat = self, .source = source, .self_id = id, .arena = arena, .origin = origin };
    turn.opaque_message = switch (msg) {
        .delivery => null,
        .owned => |body| body,
    };
    var refusal: ?[]const u8 = null;
    var reply_copied = false;
    const result: anyerror!model.Argument = switch (msg) {
        .delivery => |delivery| switch (box.handle(box.ptr, &turn, delivery)) {
            .returned => |value| value,
            .viewed => |value| copied: {
                if (turn.forwarded) break :copied .{ .void = {} };
                const owned = value.toOwned(arena) catch |err| break :copied err;
                reply_copied = true;
                break :copied owned;
            },
            .refused => |failure| refused: {
                refusal = failure.name;
                break :refused failure.localError();
            },
        },
        .owned => |body| owning: {
            const handle = box.handleOpaque orelse break :owning Error.UnsupportedDelivery;
            if (handle(box.ptr, &turn, body)) |reason| {
                refusal = reason;
                break :owning Error.OpaqueHandlerRefused;
            }
            break :owning .{ .void = {} };
        },
    };
    if (result) |value| {
        var reply = value;
        if (turn.forwarded) {
            reply = .{ .void = {} };
        } else {
            // The actor's outermost frame installs a pending become at unwind.
            // Its reply may borrow the box that installation frees, including
            // when an inner frame staged the replacement. Preserve those bytes
            // before promoting this frame's become or committing its sends.
            // POD replies and moved bytes already outlive the box. Nested
            // frames need no copy because they cannot install the replacement.
            // A become promoted by an inner frame survives an outer failure.
            // The served path copies its reply while the original box is live.
            const cell_now = self.actors.getPtr(id).?; // a running actor is never removed
            const install_at_unwind = cell_now.running == 1 and
                (turn.pending_become != null or cell_now.pending_become != null);
            if (install_at_unwind and !reply_copied and !replyOutlivesBox(self, value, turn.moves_begin)) {
                reply = model.cloneArgument(arena, value) catch |err| {
                    failFrame(self, &turn, @errorName(err));
                    return err;
                };
            }
        }
        // Reply preservation can still refuse. Publish effects only after it
        // succeeds, with the replacement state ready to install at unwind.
        commitFrame(self, &turn);
        return reply;
    } else |err| {
        // Bytes a failed turn `moveOut`ed are already vat-held (freed at the
        // next outermost turn). The staged become is released here; the
        // outermost frame's held sends drop when it closes.
        // Forwarding owns settlement once it captured the answer. A failed
        // forward breaks it through rollback, preserving the original reason.
        // An answerless forward captured no completion owner. Keep its refusal
        // for input retirement even though no caller awaits a reply.
        if (refusal) |reason| {
            if (turn.origin == .eventual) switch (turn.origin.eventual.outcome.*) {
                .pending, .discarded => turn.origin.eventual.outcome.* = .{ .broken = reason },
                .deferred, .broken => {},
            };
        }
        failFrame(self, &turn, refusal orelse @errorName(err));
        return err;
    }
}

/// Whether a handler's reply stays valid after this turn's `become` frees
/// the actor's old state box: a POD arm cannot alias the box, and bytes
/// the turn moved to the vat (`Turn.moveOut` / `moveOutString`) are
/// vat-owned and outlive it. The pointer-identity scan covers every
/// allocation moved since this turn began, O(moves-in-turn), O(1) in
/// practice, so a handler that moves several fields may return any of
/// them, while a reply borrowing any *other* state is still severed.
fn replyOutlivesBox(self: *const Vat, value: model.Argument, moves_begin: ?usize) bool {
    const reply: []const u8 = switch (value) {
        .integer, .boolean, .void, .float64 => return true,
        .bytes => |bytes| bytes,
        .string => |string| string,
        else => return false,
    };
    const begin = moves_begin orelse return false;
    for (self.moved_replies.items[begin..]) |moved| {
        if (reply.ptr == moved.ptr) return true;
    }
    return false;
}

/// End one frame of an actor's reentrant run. When the last frame unwinds,
/// install any promoted `become`: swap the actor's live box for the new one,
/// releasing the old live reference (a snapshot that shares it keeps it status-allow: replacement state identity
/// alive). Deferring the swap to zero depth is what keeps a running outer
/// frame's `self` valid across a reentrant inner become.
fn finishCellRun(self: *Vat, id: u64) void {
    // A running actor is never removed (the `callLocal` invariant, upheld by
    // `releaseActor` deferring a root-zero removal to this unwind).
    const cell = self.actors.getPtr(id).?;
    cell.running -= 1;
    if (cell.running != 0) return;
    if (cell.pending_become) |next| {
        cell.pending_become = null;
        // Retire rather than release: a reply handed back by an earlier frame of status-allow: event or source ordering
        // this same actor may still borrow the outgoing box, and that frame has
        // already returned, so no sever can reach it. `stageBecome` reserved this
        // slot, so the append cannot fail here during unwind.
        self.retired_boxes.appendAssumeCapacity(cell.box);
        cell.box = next;
    }
    // A handler that released its own last root (ADR-0014) finishes its turn
    // on live state; the retire happens here, at the frame the deferral named.
    if (cell.roots == 0) retireActorRow(self, id);
}

/// Retire a zero-rooted, non-running actor row (ADR-0014): remove the row and
/// park its box until the next outermost-turn boundary, the borrowed-reply
/// lifetime, so a reply an earlier turn handed out never dangles. Registration status-allow: event or source ordering
/// escrowed one retired-list slot for every live actor. Removing this row
/// releases that exact obligation before the append consumes it, so this path
/// is allocation-free even in destructor and frame-unwind contexts. A staged
/// become can be pending here only while frames still run, and a running actor
/// is never retired, so the row's box is the only parked one.
pub fn retireActorRow(self: *Vat, id: u64) void {
    const removed = self.actors.fetchRemove(id) orelse unreachable;
    std.debug.assert(removed.value.running == 0);
    std.debug.assert(removed.value.pending_become == null);
    self.retired_boxes.appendAssumeCapacity(removed.value.box);
}

/// Drop the vat's reference to every retired box without changing the backing
/// reservation. A destructor may release the last root of a sibling actor, so
/// remove each box before running its destructor and continue through anything
/// it retires. Turn-boundary preparation decides transactionally whether a
/// burst-sized list should be replaced. Teardown needs only this infallible
/// release. A snapshot sharing a box keeps it alive past the boundary.
fn releaseRetiredBoxes(self: *Vat) void {
    while (self.retired_boxes.pop()) |box| releaseBox(self.allocator, box);
}
