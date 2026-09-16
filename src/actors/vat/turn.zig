//! The vat's turn machinery: frames, arenas, and the synchronous call spine.
//!
//! `Turn` is the per-turn context every handler receives — its authority to
//! spawn, near-call, eventual-send, `become`, forward, and move replies out.
//! The frame spine here (`openTurnFrame`/`closeTurnFrame` around `callLocal`)
//! is the one dispatch path both the near-call and the wire deliver run, and
//! the turn/moved-reply arenas reset on its outermost boundaries. The `Vat`
//! re-binds nothing from here except through `near`; the sibling serve module
//! runs the same spine for inbound delivers.

const std = @import("std");
const engine = @import("engine");
const model = @import("model");

const boxed = @import("boxed.zig");
const serve = @import("serve.zig");
const forwarding = @import("forwarding.zig");
const vat_mod = @import("mod.zig");

const Message = vat_mod.Message;
const Ref = vat_mod.Ref;
const Vow = vat_mod.Vow;
const Error = vat_mod.Error;
const Vat = vat_mod.Vat;
const Port = vat_mod.Port;
const PendingBecome = boxed.PendingBecome;
const StateBox = boxed.StateBox;
const releaseBox = boxed.releaseBox;

/// Cap on synchronous near-call (`$`) nesting depth. Eventual-sends do not count
/// (they queue and drive iteratively); only a handler that near-calls another
/// actor that near-calls back recurses the native stack, so this bounds that
/// recursion well below a stack overflow while leaving ample room for the few
/// levels real code nests.
const max_near_call_depth: u32 = 128;

/// The per-turn context handed to an actor's handler. It is the actor's authority
/// to spawn, near-call, and eventual-send, plus its own identity. An explicit
/// argument, never global: the Zig answer to Goblins's `current-syscaller`.
pub const Turn = struct {
    vat: *Vat,
    /// Session projection inherited by work caused through a Port. Null for a
    /// pure-local turn.
    port: ?*Port,
    self_ref: Ref,
    /// Causal queue owner. Near-calls and local sends inherit this id, so an
    /// ingress cannot evade admission by bouncing through another actor.
    ingress: vat_mod.IngressId,
    /// A per-turn allocator for the handler's reply and any scratch. The vat owns
    /// it and reclaims it when its next top-level turn begins, so a handler
    /// allocates from it freely and never frees the result. Nested near-calls and
    /// sends made inside one turn share it; it is reset only when an outermost turn
    /// begins.
    arena: std.mem.Allocator,
    /// A pending `become` staged by this turn, or null. Installed when the turn
    /// frame returns successfully; discarded (its box released) on a handler error.
    pending_become: ?PendingBecome = null,
    /// Where this turn came from — the one axis `forward` dispatches on. No
    /// default: every constructor states the provenance, and the old illegal
    /// combination (a near-call carrying a wire answer) is unrepresentable.
    origin: union(enum) {
        /// A synchronous near-call (`$`), whose caller consumes a value.
        local,
        /// A queued eventual call, whose local answer can be deferred.
        eventual: struct { answer: ?u64, outcome: *EventualOutcome },
        /// An inbound wire deliver, carrying the answer this turn must settle,
        /// or null for a no-answer deliver (a wire `tell`). `forward` defers
        /// the answer onto the forwarded send's vow.
        served: ?engine.AnswerTarget,
    },
    /// Set by `forward`: this turn handed its answer off to a forwarded send's
    /// vow, so `serve` must not resolve it from the handler's return value.
    forwarded: bool = false,
    /// Index into `Vat.moved_replies` where this turn's `moveOut` transfers
    /// began (set on the turn's first move; null when nothing was moved). The
    /// vat already holds the bytes; this field only lets `callLocal` recognize
    /// a returned reply as one of the allocations this turn moved — any of
    /// them, not just the last — so a vat-owned reply outlives a same-turn
    /// `become` with no sever-copy.
    moves_begin: ?usize = null,

    /// The handled actor's own reference, for replying with itself or handing
    /// itself out as a callback.
    pub fn me(self: *const Turn) Ref {
        return self.self_ref;
    }
    /// Spawn a new actor in this vat (see `Vat.spawn`).
    pub fn spawn(self: *Turn, comptime Behavior: type, initial: Behavior) Error!Ref {
        return self.vat.spawn(Behavior, initial);
    }
    /// Synchronously call another local actor and return its reply — the `$`
    /// of this layer (see `Vat.near`).
    pub fn near(self: *Turn, target: Ref, msg: Message) anyerror!model.Argument {
        return self.vat.nearFromPort(self.port, self.ingress, target, msg);
    }
    /// Eventual-send to a local or far reference, returning the reply
    /// `Vow` — the `<-` of this layer. Pure-local turns enter through
    /// `Vat.send`; turns with a session projection enter through `Port.send`.
    pub fn send(self: *Turn, target: Ref, msg: Message) Error!Vow {
        if (self.port) |port| return port.sendFromIngress(self.vat, self.ingress, target, msg);
        return self.vat.sendFromIngress(self.ingress, target, msg);
    }
    /// Fire-and-forget eventual-send while preserving this turn's Port and
    /// causal ingress. A handler must use this rather than reaching through
    /// `turn.vat.tell`, which would reclassify the work as pure-local.
    pub fn tell(self: *Turn, target: Ref, msg: Message) Error!void {
        if (self.port) |port| return port.tellFromIngress(self.vat, self.ingress, target, msg);
        return self.vat.tellFromIngress(self.ingress, target, msg);
    }
    /// Functional "become" for a persistent actor (mirrors Goblins `bcom`): stage
    /// `next` as this actor's state. The new value is installed when this turn
    /// frame returns successfully and discarded if the handler errors, so a failed
    /// turn leaves the actor unchanged. If the frame is a reentrant near-call into
    /// an actor already running an outer frame, the install waits for that outer
    /// frame, so the box the outer frame holds as `self` is never freed under it.
    /// A persistent actor never mutates its `self`; it calls `become` instead,
    /// which is why a snapshot can share its state with no copy-on-write. Calling
    /// it twice in one turn keeps the last value. Legal only for a local self-ref.
    /// `next` is consumed on every outcome: on failure its resources are
    /// reclaimed through the state's `deinit`, so the caller never frees it.
    pub fn become(self: *Turn, comptime Behavior: type, next: Behavior) Error!void {
        return boxed.stageBecome(self.vat, self, Behavior, next);
    }

    /// Move an owned byte field out of the actor's state into the reply: hand
    /// the bytes to the vat, clear the field so the actor's `deinit` no longer
    /// frees them, and return them as a `bytes` argument. A transfer, not a
    /// borrow — the vat frees the bytes when its next outermost turn begins,
    /// the same lifetime a borrowed reply has — so handing off a large buffer
    /// is O(1) where copying it onto the turn arena is O(len), and the reply
    /// outlives a same-turn `become` with no sever-copy.
    ///
    /// Clearing the field *is* the move: no second owner survives, so the vat's
    /// free can never race the state's `deinit`. That makes the two obligations
    /// structural rather than remembered — the field must be a mutable slice
    /// the actor's state owns on the vat's allocator (the same allocator its
    /// `deinit` would free it with). A `*const` persistent handler cannot take
    /// `&self.field` mutably, so it cannot call this; it severs through the
    /// ordinary borrowed-reply path instead.
    ///
    /// The parameter is a mutable pointer for a reason, and that reason is why
    /// no wrapper type is owed. A borrow or a copy would take the bytes by
    /// value; only a transfer asks for `&self.field`, so the pointer already
    /// says the field is being given away. Clearing it to empty makes that
    /// structural: a handler that reuses the field reads empty bytes, never
    /// freed storage. A newtype guarding against silent reuse would tax every
    /// actor's state definition for a mistake the sever already turns into a
    /// harmless empty read, so `moveOut` stays a function that takes the field
    /// and nulls it. The cleared-field contract is pinned by the "leaves the
    /// field cleared" test.
    ///
    /// On out-of-memory the field is left exactly as it was. A handler error
    /// after a successful move does not restore the field — mutable-actor
    /// state changes never roll back — and the moved bytes are still freed by
    /// the vat, so nothing leaks.
    ///
    /// Eventual-path accounting, honestly: on a listened `send` then `drive`
    /// path the moved reply is still cloned once for the listener —
    /// necessarily, because a listener-opened top-level turn would drain the
    /// moved bytes mid-call — so the full O(1) win is on `near` and `tell`; a
    /// listened send saves only the become sever-copy.
    pub fn moveOut(self: *Turn, field: *[]u8) Error!model.Argument {
        return .{ .bytes = try self.moveOutSlice(field) };
    }

    /// `moveOut`'s string arm: the same O(1) transfer, returned as a `string`
    /// argument for text the actor owns as a byte buffer. One mechanism, two
    /// wire arms; every `moveOut` obligation and lifetime applies unchanged.
    pub fn moveOutString(self: *Turn, field: *[]u8) Error!model.Argument {
        return .{ .string = try self.moveOutSlice(field) };
    }

    fn moveOutSlice(self: *Turn, field: *[]u8) Error![]const u8 {
        const bytes = field.*;
        if (bytes.len == 0) return bytes;
        if (self.moves_begin == null) self.moves_begin = self.vat.moved_replies.items.len;
        try self.vat.moved_replies.append(self.vat.allocator, bytes);
        field.* = &.{};
        return bytes;
    }

    /// Forward this turn's call to `target` and let this actor's own answer
    /// resolve to the target's eventual result, the primitive a forwarding
    /// proxy (caretaker, attenuator) is built on. Goblins expresses this as a
    /// behavior that returns `(apply <- target args)`; glowcap's handler returns
    /// a concrete value, so `forward` instead defers the inbound answer and
    /// settles it when the forwarded send settles, local or far. `target` may be
    /// local or far: a far forward is what lets a holder hand out an attenuated
    /// or revocable view of a capability it imported over the wire.
    ///
    /// What comes back depends on the turn's `origin`: a `.local` frame gets
    /// the target's real value (the vat consumes the return directly, so the
    /// forward runs as a synchronous near-call); an eventual or served turn gets a `void`
    /// placeholder the vat ignores, with the real answer riding the forwarded
    /// vow — or, for a no-answer `tell`, a fire-and-forget forward.
    /// Forwarding does not preserve promise pipelining *through* the proxy: a
    /// partner pipelining on the proxy's answer queues on this side until the
    /// forwarded send settles (ADR-0064).
    pub fn forward(self: *Turn, target: Ref, msg: Message) anyerror!model.Argument {
        return forwarding.forwardTurn(self.vat, self, target, msg);
    }

    /// Defer this turn's answer onto `vow` (ADR-0102): the answer settles
    /// when the vow does. The behavior-side half of off-turn settlement — a
    /// handler mints a resolver pair (`Vat.spawnVow`), forwards its answer
    /// here, hands the resolver to whatever completes the work, and returns
    /// normally; the eventual `Vat.fulfillVow` / `Vat.breakVow` settles the
    /// answer as its own top-level event. Eventual and served turns can defer;
    /// synchronous near calls refuse (`NotLocal`). A no-answer tell has nothing
    /// to defer and is simply marked forwarded.
    pub fn forwardVow(self: *Turn, vow: Vow) anyerror!void {
        return forwarding.forwardTurnVow(self.vat, self, vow);
    }

    /// Reserve the fallible half of a vow deferral without publishing the vow.
    /// Host adapters use this to make resolver mint + turn deferral one atomic
    /// operation across their own row tables and the Vat.
    pub fn reserveForwardVow(self: *Turn, location: vat_mod.VowLocation) anyerror!forwarding.ForwardReservation {
        return forwarding.reserveForward(self.vat, self, location);
    }

    /// Commit a fresh vow into a reservation returned by `reserveForwardVow`.
    /// No allocation or refusal remains after the reservation succeeds.
    pub fn forwardReservedVow(self: *Turn, reservation: forwarding.ForwardReservation, vow: Vow) void {
        forwarding.commitForward(self.vat, self, reservation, vow);
    }

    /// Break this turn's own answer with `message` — the eventual-turn spelling
    /// of a handler failure that must carry its diagnostic. A native handler
    /// breaks by returning an error, whose `@errorName` becomes the reason; a
    /// hosted behavior's return code carries no message at all, so this verb
    /// is how a caretaker's "Revoked" or an attenuator's "Attenuated" crosses
    /// the boundary intact. A wire answer breaks now; a queued local answer
    /// breaks after the handler unwinds. A tell has no answer to break. The
    /// turn is marked forwarded so the handler's
    /// eventual return value resolves nothing — the handler still returns
    /// normally after calling this. A second call in the same turn is a no-op:
    /// answer already has its outcome. A synchronous `.local` frame's
    /// caller consumes the return value directly, so a break has
    /// nowhere to land and the handler raises instead (`NotLocal`).
    pub fn breakWith(self: *Turn, message: []const u8) !void {
        switch (self.origin) {
            .served => |answer| {
                if (self.forwarded) return;
                try serve.resolveBreak(self.port.?, answer, message);
                self.forwarded = true;
            },
            .eventual => |eventual| {
                if (self.forwarded) return;
                eventual.outcome.* = if (eventual.answer != null)
                    .{ .broken = try self.arena.dupe(u8, message) }
                else
                    .discarded;
                self.forwarded = true;
            },
            .local => return Error.NotLocal,
        }
    }
};

/// Stack-owned completion of one queued call. A deferral transfers settlement
/// to its listener; a diagnostic is owned by the turn arena until dispatch ends.
const EventualOutcome = union(enum) { returned, deferred, discarded, broken: []const u8 };

pub fn callQueued(self: *Vat, port: ?*Port, ingress: vat_mod.IngressId, id: u64, msg: Message, answer: ?u64) ?vat_mod.Resolution {
    var outcome: EventualOutcome = .returned;
    const result = callWithOrigin(self, port, ingress, id, msg, .{ .eventual = .{ .answer = answer, .outcome = &outcome } });
    return switch (outcome) {
        .returned => if (result) |value| .{ .fulfilled = value } else |err| .{ .broken = @errorName(err) },
        .deferred => null,
        .discarded => .{ .fulfilled = .{ .void = {} } },
        .broken => |reason| .{ .broken = reason },
    };
}

/// Free every reply a handler moved to the vat and not yet reclaimed. Called
/// when an outermost turn begins (mirroring the turn arena's reset) and at
/// teardown, so a moved reply lives exactly as long as a borrowed one would.
pub fn drainMovedReplies(self: *Vat) void {
    for (self.moved_replies.items) |bytes| self.allocator.free(bytes);
    self.moved_replies.clearRetainingCapacity();
    if (self.moved_replies.capacity * @sizeOf([]const u8) > vat_mod.steady_list_bytes) {
        self.moved_replies.clearAndFree(self.allocator);
    }
}

/// Open a top-level or nested turn and hand back its scratch allocator. The
/// arena is reset only when an *outermost* turn opens (depth was 0), so a turn
/// keeps its scratch live across any near-calls and sends it makes, and the
/// previous outermost turn's reply stays valid until the next one begins.
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

fn beginTurn(self: *Vat, boundary: *TurnBoundary) std.mem.Allocator {
    if (boundary.outermost) {
        // Every allocation the boundary needs succeeded in prepareTurnBoundary,
        // so the lifetime transition below is one infallible commit.
        releaseRetiredBoxes(self);
        if (boundary.retired_replacement) |replacement| {
            self.retired_boxes.deinit(self.allocator);
            self.retired_boxes = replacement;
            boundary.retired_replacement = null;
        }
        _ = self.turn_arena.reset(.{ .retain_with_limit = vat_mod.steady_turn_arena_bytes });
        // Moved replies share the arena's lifetime, so reclaim the previous
        // outermost turn's moved bytes at the same boundary its scratch
        // resets. A borrowed reply from the last turn is now invalid too.
        drainMovedReplies(self);
    }
    self.turn_depth += 1;
    return self.turn_arena.allocator();
}

fn endTurn(self: *Vat) void {
    self.turn_depth -= 1;
}

/// One open turn frame: the actor's state box, the turn arena, and the
/// actor id whose run count the close decrements.
const TurnFrame = struct { box: *StateBox, arena: std.mem.Allocator, id: u64 };

/// The one turn-open spine both dispatch paths (`callLocal`,
/// `serveDeliver`) run: bound the near-call depth, refuse a missing actor,
/// copy-on-write a snapshot-shared box, mark the frame running, and open
/// the turn arena — in exactly that order, because a refusal must happen
/// before the arena resets or the frame is marked running, so a refused
/// dispatch leaves the vat untouched. The box pointer is read out before
/// the handler runs: a handler may spawn, which can resize `actors` and
/// invalidate the cell pointer. Close with `defer closeTurnFrame(id)`.
pub fn openTurnFrame(self: *Vat, id: u64) Error!TurnFrame {
    // Bound the near-call recursion before it can overflow the native
    // stack: each nested `$` deepens `turn_depth`, so refuse once it would
    // exceed the cap rather than crashing on a cyclic local graph.
    if (self.turn_depth >= max_near_call_depth) return Error.NearCallTooDeep;
    const cell = self.actors.getPtr(id) orelse return Error.NoSuchActor;
    var boundary = try prepareTurnBoundary(self);
    errdefer boundary.deinit(self.allocator);
    try boxed.ensureUnshared(self, cell);
    const box = cell.box;
    const arena = beginTurn(self, &boundary);
    cell.running += 1;
    return .{ .box = box, .arena = arena, .id = id };
}

/// Unwind an open turn frame: install any promoted `become` only when this
/// actor's outermost frame unwinds (so a reentrant inner become never
/// frees the box an outer frame is still running as `self`), then close
/// the turn — `finishCellRun` before `endTurn`, the order the two paths'
/// paired defers always ran in.
pub fn closeTurnFrame(self: *Vat, id: u64) void {
    finishCellRun(self, id);
    endTurn(self);
}

pub fn callLocal(self: *Vat, port: ?*Port, ingress: vat_mod.IngressId, id: u64, msg: Message) anyerror!model.Argument {
    return callWithOrigin(self, port, ingress, id, msg, .local);
}

fn callWithOrigin(self: *Vat, port: ?*Port, ingress: vat_mod.IngressId, id: u64, msg: Message, origin: @FieldType(Turn, "origin")) anyerror!model.Argument {
    const frame = try openTurnFrame(self, id);
    const box = frame.box;
    const arena = frame.arena;
    defer closeTurnFrame(self, id);
    var turn = Turn{ .vat = self, .port = port, .self_ref = .{ .local = id }, .ingress = ingress, .arena = arena, .origin = origin };
    if (box.handle(box.ptr, &turn, msg)) |value| {
        if (turn.forwarded) {
            if (turn.pending_become) |pending| boxed.promoteBecome(self, pending);
            return .{ .void = {} };
        }
        // A become installing at this frame's unwind makes the deferred
        // `finishCellRun` free this actor's old state box as the call
        // returns, but `value` may borrow that state — the module contract
        // invites a reply that aliases `self`. The install happens exactly
        // when this is the actor's outermost frame (`running == 1` here,
        // since this frame still counts) AND a become is staged on this
        // frame or was promoted by an inner reentrant frame — the inner
        // case is why `turn.pending_become` alone is not the gate: an
        // inner `become` with a null outer stage would otherwise free the
        // box under the outer frame's aliased reply. A reply that provably
        // outlives the box (a POD arm, or bytes this turn `moveOut`ed to
        // the vat) is returned as-is; everything else is severed onto the
        // turn arena, which outlives the box free and stays valid until
        // the next outermost turn (the reply's documented lifetime), so
        // near-callers and `settleLocal` read live bytes. An inner frame
        // (`running > 1`) never severs — no install happens at its unwind,
        // so the copy would be pure waste. Clone before promoting so an
        // OOM leaves this frame's become unstaged and the box untouched —
        // the turn stays all-or-nothing (an inner frame's already-promoted
        // become survives; promotion is per-frame). `serve` needs no such
        // guard: it copies the reply out (`resolveFulfill`) inside the
        // turn window, before `finishCellRun` runs.
        const cell_now = self.actors.getPtr(id).?; // a running actor is never removed
        const install_at_unwind = cell_now.running == 1 and
            (turn.pending_become != null or cell_now.pending_become != null);
        if (install_at_unwind and !replyOutlivesBox(self, value, turn.moves_begin)) {
            const severed = model.cloneArgument(arena, value) catch |err| {
                if (turn.pending_become) |pending| releaseBox(self.allocator, pending.box);
                return err;
            };
            if (turn.pending_become) |pending| boxed.promoteBecome(self, pending);
            return severed;
        }
        if (turn.pending_become) |pending| boxed.promoteBecome(self, pending);
        return value;
    } else |err| {
        // Bytes a failed turn `moveOut`ed are already vat-held (freed at the
        // next outermost turn), so only the staged become needs discarding.
        if (turn.pending_become) |pending| releaseBox(self.allocator, pending.box);
        return err;
    }
}

/// Whether a handler's reply stays valid after this turn's `become` frees
/// the actor's old state box: a POD arm cannot alias the box, and bytes
/// the turn moved to the vat (`Turn.moveOut` / `moveOutString`) are
/// vat-owned and outlive it. The pointer-identity scan covers every
/// allocation moved since this turn began — O(moves-in-turn), O(1) in
/// practice — so a handler that moves several fields may return any of
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
/// releasing the old live reference (a snapshot that shares it keeps it
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
        // Retire rather than release: a reply handed back by an earlier frame of
        // this same actor may still borrow the outgoing box, and that frame has
        // already returned, so no sever can reach it. `stageBecome` reserved this
        // slot, so the append cannot fail here during unwind.
        self.retired_boxes.appendAssumeCapacity(cell.box);
        cell.box = next;
    }
    // A handler that released its own last root (ADR-0101) finishes its turn
    // on live state; the retire happens here, at the frame the deferral named.
    if (cell.roots == 0) retireActorRow(self, id);
}

/// Retire a zero-rooted, non-running actor row (ADR-0101): remove the row and
/// park its box until the next outermost-turn boundary — the borrowed-reply
/// lifetime, so a reply an earlier turn handed out never dangles. Registration
/// escrowed one retired-list slot for every live actor; removing this row
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
/// burst-sized list should be replaced; teardown needs only this infallible
/// release. A snapshot sharing a box keeps it alive past the boundary.
pub fn releaseRetiredBoxes(self: *Vat) void {
    while (self.retired_boxes.pop()) |box| releaseBox(self.allocator, box);
}
