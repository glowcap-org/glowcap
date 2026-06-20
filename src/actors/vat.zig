//! A vat: a turn loop over a heap of actors, local and remote alike.
//!
//! This is pancake's Goblins-shaped actor model, expressed in native Zig. It is
//! where local actors meet the OCapN engine. A vat owns a set of local actors,
//! keyed by id, and a queue of pending eventual-sends. When it is bound to a peer,
//! it can also route sends to remote objects over the wire. You drive it
//! explicitly. It owns no I/O and no scheduler thread, so it stays in the same
//! sync, no-I/O core as the engine it rides on.
//!
//! An actor is any type with `pub fn handle(self: *@This(), turn: *Turn, msg:
//! Message) !model.Argument` (and, optionally, `pub fn deinit(self, allocator)`).
//! Its mutable `self` *is* its state: where Goblins returns a fresh behavior via
//! `bcom`, a Zig actor assigns its own fields. It is the same "become" idea,
//! expressed through Zig's ordinary mutable state.
//!
//! Ownership at the handler boundary is *turn-scoped*. The `Message` a handler
//! receives borrows its arguments for the duration of the turn. For its reply a
//! handler has two choices, and the vat reclaims storage after either. It
//! can return a value owned by its own `self` or aliased from the message, which
//! allocates nothing. Or it can allocate the reply and any scratch from
//! `turn.arena`, the per-turn allocator the vat hands every handler. The vat owns
//! that arena and resets it when its next top-level turn begins, so a handler
//! never frees its own reply and never leaks one. The reply is therefore valid
//! until the vat's next top-level turn: within that window the vat clones it for
//! the local promise's listener or clones it onto the wire (the one clone in
//! `peer.sendCopying`). To keep a value beyond your turn, store it in `self` or
//! copy it; never return storage that ends before the turn does. A `Resolution`
//! delivered to a listener follows the same rule. It is valid only for that
//! listener call, so a listener that keeps it copies first.
//!
//! An eventual-send's message is the mirror image: `send` and `tell` borrow
//! the verb and args only for the duration of the call. The local arm clones
//! them into a vat-owned queue arena (a queued turn runs at the next `drive`,
//! after the turn arena the caller built them in has been reset), and the far
//! arm clones them inside `peer.sendCopying`. Either way the caller's storage
//! is free the moment the send returns.
//!
//! Two verbs, matching Goblins:
//!   * `Vat.near` is the synchronous near-call (`$`). It runs an actor's handler
//!     immediately and returns its value. It is legal only for a local ref in the
//!     same vat, exactly as Goblins forbids `$` to a far ref.
//!   * `Vat.send` is the eventual send (`<-`). It is location-transparent: to a
//!     local ref it queues a turn, and to a far ref it sends an `op:deliver` over
//!     the bound peer. Either way it returns a `Promise` you observe with
//!     `Vat.on`.
//!
//! The unified `Ref` can name a local actor or a far object, and a `Promise`
//! can settle from a local turn or from a wire answer. An application sends to a
//! ref without caring where it lives; the vat chooses the route. The engine stays
//! focused on codecs and authority. The vat sits above it and imports the engine,
//! never the reverse.
//!
//! ## Local time-travel (snapshot / restore) — opt-in, off by default
//!
//! A vat can `snapshot` its local actor heap and later `restore` it, Goblins's
//! `snapshot-whactormap` shaped in Zig (ADR-0060). Each actor's state lives behind
//! a refcounted `StateBox`, so a snapshot shares state pointers rather than copying
//! bytes — O(objects), no per-byte clone — and the count is non-atomic because a
//! vat is single-threaded. The feature pays nothing when unused: a non-snapshotting
//! actor's box stays `refs == 1` and the turn path costs one extra pointer hop.
//!
//! There are two opt-in actor flavors, and a snapshot needs one of them:
//!   * **Mutable + `clone`.** An actor that defines `pub fn clone(self: *const
//!     @This(), allocator) std.mem.Allocator.Error!*@This()` keeps mutating its
//!     `self` and is copied-on-write: the vat deep-clones a *shared* box before the
//!     next turn can mutate it, so the snapshot's copy is never touched.
//!   * **Persistent + `become`.** An actor that declares `pub const
//!     snapshot_persistent = true;` never mutates `self`; it produces its next
//!     state with `Turn.become`. Because the value is never mutated in place, the
//!     snapshot can share it with no copy-on-write — full Goblins parity.
//! An actor that is neither cloneable nor persistent makes `snapshot` fail with
//! `NotSnapshottable`, so a silent partial snapshot is impossible.
//!
//! Time-travel is **local only.** A snapshot captures local actor state and
//! `next_actor`; it never touches `peer`, `exports`, far listeners, or the turn
//! arenas. A restore rewinds no remote peer, and far references in restored state
//! are copied as data — their wire meaning is engine-owned and forward-only. Both
//! `snapshot` and `restore` require quiescence (no turn or drive in flight, empty
//! queue), else `NotQuiescent`.

const std = @import("std");
const model = @import("model");
const engine = @import("engine");

/// A reference the vat can eventual-send to, wherever the object lives.
pub const Ref = union(enum) {
    /// An actor in this vat. `near` and `send` run its turns here.
    local: u64,
    /// A partner-hosted object the bound peer holds as an import. `send` routes
    /// to it as an `op:deliver`; `near` is illegal.
    far: model.FarRef,
};

/// A handle to the eventual result of a `Vat.send`.
pub const Promise = union(enum) {
    /// Result of a local send; settled by `Vat.drive`.
    local: u64,
    /// Result of a far send; the outbound answer position the partner resolves.
    far: model.AnswerId,
};

/// A message to an actor: a verb (method selector) and its arguments. From the
/// handler's side the verb and args are borrowed for the duration of the turn:
/// a handler never frees them, and one that keeps a value past its turn copies
/// it first.
pub const Message = struct {
    verb: []const u8,
    args: []const model.Argument = &.{},

    pub fn arg(self: Message, i: usize) model.Argument {
        return self.args[i];
    }
};

/// How a promise settled. The carried value (`fulfilled` argument or `broken`
/// message) is borrowed only for the duration of the listener call. A listener
/// that retains it copies first.
pub const Resolution = union(enum) {
    fulfilled: model.Argument,
    broken: []const u8,
};

/// A one-shot promise listener: `func(ctx, resolution)` fires when the promise
/// settles. `ctx` is the caller's opaque state (or null).
pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, resolution: Resolution) void,
};

pub const Error = error{
    /// A `Ref` named no actor in this vat.
    NoSuchActor,
    /// A near-call (`near` / `$`) was made to a far ref; only `send` reaches one.
    NotNearCallable,
    /// `Vat.bindExport` was given a far ref: only a local actor can be bound to
    /// an export position this vat answers for. Also returned by `Turn.become`
    /// for a far self-ref, which cannot happen for a running local handler but
    /// keeps the surface total.
    NotLocal,
    /// A far `send` was made on a vat with no bound peer.
    NotConnected,
    /// `Vat.bindExport` was called for an export position already bound to an
    /// actor. Re-binding it would silently orphan the first actor, so it fails
    /// loudly. Which local object answers an export position is authority.
    AlreadyPublished,
    /// `Vat.on` was called for a promise that already holds a listener.
    /// Listeners are one-shot and a promise holds at most one, so replacing it
    /// would silently orphan the first, the same rule `bindExport` applies to
    /// export positions.
    AlreadyListening,
    /// The bound peer refused an outbound far `send` for a session or protocol
    /// reason: an invalid reference, an unnegotiated feature, a closed
    /// session, a resource cap, or an encode failure. Distinct from
    /// `OutOfMemory`, which stays reserved for genuine allocator exhaustion.
    SendRejected,
    /// A chain of synchronous near-calls (`$`) nested past `max_near_call_depth`.
    /// This guards a buggy or cyclic local actor graph from overflowing the native
    /// stack. For example, actor A near-calls B, which near-calls A again. This is
    /// not a wire bound; inbound frames never drive a near-call.
    NearCallTooDeep,
    /// `Vat.snapshot` or `Vat.restore` was called while a turn or drive was in
    /// flight or the send queue was non-empty. Time-travel is only coherent at
    /// quiescence: a snapshot taken mid-turn would capture a half-mutated heap.
    NotQuiescent,
    /// `Vat.snapshot` reached an actor that is neither cloneable (no `clone`
    /// method) nor persistent (`snapshot_persistent`), so its mutable state
    /// cannot be safely shared with a snapshot. The snapshot fails whole rather
    /// than silently omitting the actor.
    NotSnapshottable,
} || std.mem.Allocator.Error;

/// Cap on synchronous near-call (`$`) nesting depth. Eventual-sends do not count
/// (they queue and drive iteratively); only a handler that near-calls another
/// actor that near-calls back recurses the native stack, so this bounds that
/// recursion well below a stack overflow while leaving ample room for the few
/// levels real code nests.
const max_near_call_depth: u32 = 128;

/// Whether a behavior is a *persistent* actor: it never mutates `self` and
/// produces its next state with `Turn.become`, so a snapshot may share its state
/// with no copy-on-write. Opt in with `pub const snapshot_persistent = true;`.
fn behaviorIsPersistent(comptime Behavior: type) bool {
    return @hasDecl(Behavior, "snapshot_persistent") and Behavior.snapshot_persistent;
}

/// A refcounted home for one actor's state. A `Cell` holds a `*StateBox`, and a
/// snapshot shares that pointer instead of copying the bytes behind it. The count
/// is non-atomic because a vat is single-threaded, and an immutable/shared state
/// value never points back at a box, so the graph is acyclic and a plain count
/// frees correctly with no collector. The behavior's identity travels in the box
/// (`handle`/`destroy`/`clone`) so a snapshot can rebuild a working cell from a
/// shared box alone.
const StateBox = struct {
    ptr: *anyopaque,
    /// Live references: the vat's own cell plus one per snapshot that shares it.
    refs: usize,
    handle: *const fn (state: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument,
    destroy: *const fn (state: *anyopaque, allocator: std.mem.Allocator) void,
    /// Deep-copy this box's state into a fresh allocation, for copy-on-write.
    /// Null when the actor opted out of cloning; such a box is snapshottable only
    /// if it is `persistent`.
    clone: ?*const fn (state: *anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error!*anyopaque,
    /// Set at spawn for a persistent actor: its state is never mutated in place,
    /// so copy-on-write is skipped and a snapshot shares it directly.
    persistent: bool,
};

/// One actor slot in the vat's heap: a single owning reference to a `StateBox`.
const Cell = struct { box: *StateBox };

/// A staged `Turn.become`: the next state box, installed when the turn frame
/// returns successfully and discarded if the handler errors.
const PendingBecome = struct { id: u64, box: *StateBox };

/// Release one reference to `box`, freeing its state and the box itself when the
/// last reference drops. The single chokepoint for box lifetime, shared by the
/// vat and by `Snapshot.deinit` so both count the same way.
fn releaseBox(allocator: std.mem.Allocator, box: *StateBox) void {
    box.refs -= 1;
    if (box.refs == 0) {
        box.destroy(box.ptr, allocator);
        allocator.destroy(box);
    }
}

/// A captured local actor heap: a point-in-time sharing of each actor's
/// `StateBox` (refcount raised, no bytes copied) plus the `next_actor` counter.
/// Reusable across repeated `restore`s. The owner frees it with `deinit`, which
/// drops the snapshot's reference to every shared box. Captures local state
/// only, never `peer`, `exports`, far listeners, or the turn arenas.
pub const Snapshot = struct {
    boxes: std.AutoHashMapUnmanaged(u64, *StateBox) = .{},
    next_actor: u64 = 1,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Snapshot) void {
        var it = self.boxes.valueIterator();
        while (it.next()) |box| releaseBox(self.allocator, box.*);
        self.boxes.deinit(self.allocator);
        self.* = undefined;
    }
};

/// The per-turn context handed to an actor's handler. It is the actor's authority
/// to spawn, near-call, and eventual-send, plus its own identity. An explicit
/// argument, never global: the Zig answer to Goblins's `current-syscaller`.
pub const Turn = struct {
    vat: *Vat,
    self_ref: Ref,
    /// A per-turn allocator for the handler's reply and any scratch. The vat owns
    /// it and reclaims it when its next top-level turn begins, so a handler
    /// allocates from it freely and never frees the result. Nested near-calls and
    /// sends made inside one turn share it; it is reset only when an outermost turn
    /// begins.
    arena: std.mem.Allocator,
    /// A pending `become` staged by this turn, or null. Installed when the turn
    /// frame returns successfully; discarded (its box released) on a handler error.
    pending_become: ?PendingBecome = null,
    /// The answer this turn must settle, set by `serve` for an inbound deliver
    /// (null for a `tell` with no answer, or a near-call). `forward` reads it to
    /// defer resolution onto a forwarded send's promise.
    inbound_answer: ?model.AnswerId = null,
    /// Set by `forward`: this turn handed its answer off to a forwarded send's
    /// promise, so `serve` must not resolve it from the handler's return value.
    forwarded: bool = false,
    /// True while this turn runs under a synchronous near-call (`$`), where the
    /// caller wants a value back now. `forward` then forwards by near-call to a
    /// local target and returns its value rather than deferring an answer.
    near_call: bool = false,

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
        return self.vat.near(target, msg);
    }
    /// Eventual-send to a local or far reference, returning the reply
    /// `Promise` — the `<-` of this layer (see `Vat.send`).
    pub fn send(self: *Turn, target: Ref, msg: Message) Error!Promise {
        return self.vat.send(target, msg);
    }
    /// Functional "become" for a persistent actor (mirrors Goblins `bcom`): stage
    /// `next` as this actor's state. The new value is installed when this turn
    /// frame returns successfully and discarded if the handler errors, so a failed
    /// turn leaves the actor unchanged. A persistent actor never mutates its
    /// `self`; it calls `become` instead, which is why a snapshot can share its
    /// state with no copy-on-write. Calling it twice in one turn keeps the last
    /// value. Legal only for a local self-ref.
    pub fn become(self: *Turn, comptime Behavior: type, next: Behavior) Error!void {
        return self.vat.stageBecome(self, Behavior, next);
    }

    /// Forward this turn's call to `target` and let this actor's own answer
    /// resolve to the target's eventual result, the primitive a forwarding
    /// proxy (caretaker, attenuator) is built on. Goblins expresses this as a
    /// behavior that returns `(apply <- target args)`; pancake's handler returns
    /// a concrete value, so `forward` instead defers the inbound answer and
    /// settles it when the forwarded send settles, local or far. `target` may be
    /// local or far: a far forward is what lets a holder hand out an attenuated
    /// or revocable view of a capability it imported over the wire.
    ///
    /// The return is a `void` placeholder the vat ignores; the real answer rides
    /// the forwarded promise. A turn with no inbound answer (a `tell`) forwards
    /// fire-and-forget. Forwarding does not preserve promise pipelining *through*
    /// the proxy: a partner pipelining on the proxy's answer queues on this side
    /// until the forwarded send settles (ADR-0064).
    pub fn forward(self: *Turn, target: Ref, msg: Message) anyerror!model.Argument {
        return self.vat.forwardTurn(self, target, msg);
    }
};

/// Heap context a forwarded turn's promise listener carries: the vat to resolve
/// against and the deferred inbound answer. Freed by the listener once it fires
/// (on settle, or on a disconnect break via `breakFarPromises`).
const ForwardContext = struct { vat: *Vat, answer: model.AnswerId };

fn forwardListener(ctx: ?*anyopaque, resolution: Resolution) void {
    const fc: *ForwardContext = @ptrCast(@alignCast(ctx.?));
    defer fc.vat.allocator.destroy(fc);
    // Best-effort: a failed resolve strands the partner's answer until teardown
    // (the same class as a refused GC release), never a fault on this side.
    switch (resolution) {
        .fulfilled => |value| fc.vat.resolveFulfill(fc.answer, value) catch {},
        .broken => |message| fc.vat.resolveBreak(fc.answer, message) catch {},
    }
}

/// One single-threaded container of local objects, the Goblins-shaped layer
/// above the engine. Spawn objects, near-call them with `near` (`$`),
/// eventual-send with `send` (`<-`), and `drive` queued turns to completion;
/// bind a peer and the same sends reach far references. Sync and no-I/O by
/// contract (ADR-0036): the vat only enqueues onto its peer's outbound queue
/// and reads its events. Everything spawned or queued lives on the vat's
/// allocator and arenas, freed in `deinit`.
pub const Vat = struct {
    allocator: std.mem.Allocator,
    /// The peer this vat rides on, or null for a pure-local vat. Far sends and
    /// hosting require it; the vat still owns no I/O. It only enqueues onto the
    /// peer's outbound queue and reads its events.
    peer: ?*engine.Peer = null,
    actors: std.AutoHashMapUnmanaged(u64, Cell) = .{},
    queue: std.ArrayList(Queued) = .empty,
    listeners: std.AutoHashMapUnmanaged(u64, Listener) = .{},
    /// Listener for a far send's promise, keyed by outbound answer position.
    far_listeners: std.AutoHashMapUnmanaged(model.AnswerId, Listener) = .{},
    /// Local actor id for each export position published on the peer.
    exports: std.AutoHashMapUnmanaged(u64, u64) = .{},
    /// Per-turn scratch the vat hands each handler as `turn.arena`. A handler's
    /// reply and scratch live here; the vat reclaims the whole arena when its next
    /// outermost turn begins (when `turn_depth` returns to 0 and rises again), so a
    /// reply stays valid until then and no handler frees or leaks its own reply.
    turn_arena: std.heap.ArenaAllocator,
    /// Owns every queued local eventual-send's message clone. A queued turn runs
    /// at the next `drive`, after the turn arena the sender built its args in has
    /// been reset, so the queue cannot borrow them: `send`/`tell` clone the
    /// message here, and one `reset(.retain_capacity)` reclaims everything when
    /// the outermost `drive` has fully drained the queue.
    queue_arena: std.heap.ArenaAllocator,
    /// Nesting depth of in-flight turns. The turn arena resets only at depth 0, so a
    /// near-call or send made inside a turn shares that turn's scratch rather than
    /// pulling it out from under the call in flight.
    turn_depth: u32 = 0,
    /// Nesting depth of in-flight `drive` calls. A listener may open a nested
    /// `drive`; only the outermost one may reset the queue arena, or the inner
    /// reset would free messages the outer drive still holds.
    drive_depth: u32 = 0,
    next_actor: u64 = 1,
    next_promise: u64 = 1,

    const Queued = struct { target: u64, msg: Message, promise: u64 };

    /// A pure-local vat (no wire). `near`/`send`/`drive` over local actors only.
    pub fn init(allocator: std.mem.Allocator) Vat {
        return .{
            .allocator = allocator,
            .turn_arena = std.heap.ArenaAllocator.init(allocator),
            .queue_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// A vat bound to `peer`: far sends route to it, and `bindExport` binds actors
    /// to export positions so inbound deliveries (via `serve`) run their turns.
    pub fn initOver(allocator: std.mem.Allocator, peer: *engine.Peer) Vat {
        return .{
            .allocator = allocator,
            .peer = peer,
            .turn_arena = std.heap.ArenaAllocator.init(allocator),
            .queue_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Vat) void {
        var it = self.actors.valueIterator();
        while (it.next()) |cell| releaseBox(self.allocator, cell.box);
        self.actors.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.listeners.deinit(self.allocator);
        self.far_listeners.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        self.turn_arena.deinit();
        self.queue_arena.deinit();
    }

    /// Allocate a fresh `StateBox` (`refs = 1`) owning a heap copy of `initial`,
    /// wiring the behavior's `handle`/`destroy`/`clone` and persistent flavor. The
    /// one place a box is born, shared by `spawn` and `become`. On failure it owns
    /// nothing: `initial`'s resources are reclaimed before the error returns.
    fn makeBox(self: *Vat, comptime Behavior: type, initial: Behavior) Error!*StateBox {
        const Glue = struct {
            fn handle(erased: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument {
                const behavior: *Behavior = @ptrCast(@alignCast(erased));
                return behavior.handle(turn, msg);
            }
            fn destroy(erased: *anyopaque, allocator: std.mem.Allocator) void {
                const behavior: *Behavior = @ptrCast(@alignCast(erased));
                if (@hasDecl(Behavior, "deinit")) behavior.deinit(allocator);
                allocator.destroy(behavior);
            }
            fn clone(erased: *anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error!*anyopaque {
                const behavior: *const Behavior = @ptrCast(@alignCast(erased));
                // Reached only when `clone` was wired below, i.e. the actor
                // defines it; the guard keeps the body compilable for actors
                // that do not.
                if (@hasDecl(Behavior, "clone")) {
                    const fresh = try behavior.clone(allocator);
                    return @ptrCast(fresh);
                }
                unreachable;
            }
        };

        const state = try self.allocator.create(Behavior);
        // Move `initial` into the heap state *before* the next fallible step, so
        // the failure path's `deinit` reclaims a fully-formed value (the doc
        // contract) rather than reading uninitialized memory.
        state.* = initial;
        const box = self.allocator.create(StateBox) catch |e| {
            if (@hasDecl(Behavior, "deinit")) state.deinit(self.allocator);
            self.allocator.destroy(state);
            return e;
        };
        box.* = .{
            .ptr = @ptrCast(state),
            .refs = 1,
            .handle = Glue.handle,
            .destroy = Glue.destroy,
            .clone = if (@hasDecl(Behavior, "clone")) Glue.clone else null,
            .persistent = behaviorIsPersistent(Behavior),
        };
        return box;
    }

    /// Spawn a local actor with `initial` state, returning a local `Ref`. No
    /// export position is minted: a partner cannot reach the actor until it is
    /// bound with `bindExport` (or spawned through the driver's exporting
    /// `spawn`), so this is the no-grant way to create one.
    pub fn spawn(self: *Vat, comptime Behavior: type, initial: Behavior) Error!Ref {
        const box = try self.makeBox(Behavior, initial);
        errdefer releaseBox(self.allocator, box);

        const id = self.next_actor;
        try self.actors.put(self.allocator, id, .{ .box = box });
        self.next_actor += 1;
        return .{ .local = id };
    }

    /// The synchronous near-call (`$`): run `target`'s handler now and return its
    /// value. Legal only for a local ref; a far ref must be reached with `send`.
    /// The returned `Argument` is borrowed from the actor's state or the message
    /// (see the module header) and is valid only as long as both are; a caller
    /// that keeps it copies first.
    pub fn near(self: *Vat, target: Ref, msg: Message) anyerror!model.Argument {
        return switch (target) {
            .local => |id| self.callLocal(id, msg),
            .far => Error.NotNearCallable,
        };
    }

    /// Open a top-level or nested turn and hand back its scratch allocator. The
    /// arena is reset only when an *outermost* turn opens (depth was 0), so a turn
    /// keeps its scratch live across any near-calls and sends it makes, and the
    /// previous outermost turn's reply stays valid until the next one begins.
    fn beginTurn(self: *Vat) std.mem.Allocator {
        if (self.turn_depth == 0) _ = self.turn_arena.reset(.retain_capacity);
        self.turn_depth += 1;
        return self.turn_arena.allocator();
    }

    fn endTurn(self: *Vat) void {
        self.turn_depth -= 1;
    }

    /// Copy-on-write: if `cell`'s box is shared with a snapshot, deep-clone its
    /// state into a fresh box before the turn that is about to run can mutate it,
    /// so the snapshot's copy is never touched. A persistent box is skipped — it is
    /// never mutated in place — and an unshared box (`refs == 1`) costs nothing.
    /// Conservative by necessity: a read-only near-call to a shared mutable actor
    /// still clones, because mutable `self` hides reads from writes.
    fn ensureUnshared(self: *Vat, cell: *Cell) Error!void {
        const box = cell.box;
        if (box.persistent or box.refs == 1) return;
        // A shared, non-persistent box was admitted by `snapshot` only if it is
        // cloneable, so `clone` is non-null here; treat a null as "cannot COW".
        const clone_fn = box.clone orelse return;
        const fresh_ptr = try clone_fn(box.ptr, self.allocator);
        const new_box = self.allocator.create(StateBox) catch |e| {
            box.destroy(fresh_ptr, self.allocator);
            return e;
        };
        new_box.* = .{
            .ptr = fresh_ptr,
            .refs = 1,
            .handle = box.handle,
            .destroy = box.destroy,
            .clone = box.clone,
            .persistent = box.persistent,
        };
        // Drop this cell's reference to the shared box (the snapshot keeps it
        // alive, so this never frees it) and point the cell at the private copy.
        box.refs -= 1;
        cell.box = new_box;
    }

    fn callLocal(self: *Vat, id: u64, msg: Message) anyerror!model.Argument {
        // Bound the near-call recursion before it can overflow the native stack:
        // each nested `$` deepens `turn_depth`, so refuse once it would exceed the
        // cap rather than crashing on a cyclic local graph.
        if (self.turn_depth >= max_near_call_depth) return Error.NearCallTooDeep;
        const cell = self.actors.getPtr(id) orelse return Error.NoSuchActor;
        try self.ensureUnshared(cell);
        // Read the box pointer out before the handler runs: a handler may spawn,
        // which can resize `actors` and invalidate `cell`.
        const box = cell.box;
        const arena = self.beginTurn();
        defer self.endTurn();
        var turn = Turn{ .vat = self, .self_ref = .{ .local = id }, .arena = arena, .near_call = true };
        if (box.handle(box.ptr, &turn, msg)) |value| {
            if (turn.pending_become) |pending| self.installBecome(pending);
            return value;
        } else |err| {
            if (turn.pending_become) |pending| releaseBox(self.allocator, pending.box);
            return err;
        }
    }

    /// Stage `next` as the running actor's pending become (see `Turn.become`).
    fn stageBecome(self: *Vat, turn: *Turn, comptime Behavior: type, next: Behavior) Error!void {
        const id = switch (turn.self_ref) {
            .local => |a| a,
            .far => return Error.NotLocal,
        };
        const box = try self.makeBox(Behavior, next);
        // Last become in a turn wins: release any value staged earlier this turn.
        if (turn.pending_become) |prev| releaseBox(self.allocator, prev.box);
        turn.pending_become = .{ .id = id, .box = box };
    }

    /// Install a staged become: swap the actor's live box for the new one,
    /// releasing the old live reference (a snapshot that shares it keeps it alive).
    fn installBecome(self: *Vat, pending: PendingBecome) void {
        const cell = self.actors.getPtr(pending.id) orelse {
            // The actor vanished mid-turn (it cannot, today — a running actor is
            // never removed — but keep the release total rather than leak).
            releaseBox(self.allocator, pending.box);
            return;
        };
        releaseBox(self.allocator, cell.box);
        cell.box = pending.box;
    }

    /// The eventual send (`<-`): location-transparent. A local target queues a
    /// turn for `drive`; a far target sends an `op:deliver` over the bound peer
    /// (a leading symbol carries the verb, matching Goblins's `($ obj 'method …)`).
    /// Returns a `Promise` for the result. The message's verb and args are
    /// borrowed only for the duration of this call: the local arm clones them
    /// into the vat's queue arena, the far arm clones them inside
    /// `peer.sendCopying`.
    pub fn send(self: *Vat, target: Ref, msg: Message) Error!Promise {
        switch (target) {
            .local => |id| {
                const promise = self.next_promise;
                try self.queue.append(self.allocator, .{ .target = id, .msg = try self.cloneForQueue(msg), .promise = promise });
                self.next_promise += 1;
                return .{ .local = promise };
            },
            .far => |far_ref| {
                const peer = self.peer orelse return Error.NotConnected;
                const answer = model.AnswerId.from(peer.allocateAnswer());
                try self.farDeliver(far_ref, msg, answer);
                return .{ .far = answer };
            },
        }
    }

    /// Drive `Turn.forward`: forward this turn's call to `target` and arrange for
    /// the turn's inbound answer to settle when the forwarded send does.
    ///
    /// A synchronous near-call (`$`) wants a value now, so it forwards by
    /// near-call and returns the target's value directly, legal only for a local
    /// target, since `near` refuses a far ref. The eventual-send/deliver path
    /// defers: with an inbound answer it sends and settles that answer on the
    /// forwarded promise; with none (a `tell`) it forwards fire-and-forget. The
    /// placeholder return is ignored by `serve`/`callLocal` once `forwarded` is set.
    fn forwardTurn(self: *Vat, turn: *Turn, target: Ref, msg: Message) anyerror!model.Argument {
        if (turn.near_call) return self.near(target, msg);
        const answer = turn.inbound_answer orelse {
            try self.tell(target, msg);
            turn.forwarded = true;
            return .{ .void = {} };
        };
        const promise = try self.send(target, msg);
        const fc = try self.allocator.create(ForwardContext);
        fc.* = .{ .vat = self, .answer = answer };
        // A fresh promise can only collide on OOM, never `AlreadyListening`.
        self.on(promise, .{ .ctx = fc, .func = forwardListener }) catch |e| {
            self.allocator.destroy(fc);
            return e;
        };
        turn.forwarded = true;
        return .{ .void = {} };
    }

    /// Promise pipelining (the questioner half of ADR-0007): eventual-send `msg`
    /// to a far answer this vat is still awaiting — the `.far` position a prior
    /// `send` returned — instead of a settled reference. It puts one
    /// `op:deliver` against `<desc:answer answer_pos>` on the wire, so a
    /// dependent call need not wait for the answer it depends on to come back:
    /// send `create`, then `sendToAnswer(create_answer, assign)` before
    /// `create` resolves. The partner queues the call on that pending answer and
    /// drains it when the answer settles (the serving side ADR-0007 already
    /// built). Returns a `Promise` for this call's own result, which can itself
    /// be pipelined against. `msg`'s verb and args are borrowed only for this
    /// call (cloned inside `peer.sendCopying`). `NotConnected` if no peer is
    /// bound. The empty-path target rides the engine's flat `desc:answer` send;
    /// a multi-hop path is the engine's decomposition concern, not this surface.
    pub fn sendToAnswer(self: *Vat, answer_pos: model.AnswerId, msg: Message) Error!Promise {
        const peer = self.peer orelse return Error.NotConnected;
        const answer = model.AnswerId.from(peer.allocateAnswer());
        try self.farDeliverTo(.{ .promise = .{ .answer_position = answer_pos } }, msg, answer);
        return .{ .far = answer };
    }

    /// The fire-and-forget eventual-send (Goblins `<-np`): like `send`, but it
    /// requests no answer, so the partner's actor runs and sends no reply. A far
    /// `tell` puts one `op:deliver` with no answer on the wire. That is the
    /// right shape for a notification or broadcast, which would otherwise pay for
    /// a reply nobody reads. A local `tell` queues a turn whose result is
    /// discarded. Returns nothing: there is no promise to observe.
    pub fn tell(self: *Vat, target: Ref, msg: Message) Error!void {
        switch (target) {
            .local => |id| {
                // Queue a turn like `send`, but with no observable promise; the
                // promise id keeps the queue entry uniform and `drive` settles it
                // into no listener.
                const promise = self.next_promise;
                try self.queue.append(self.allocator, .{ .target = id, .msg = try self.cloneForQueue(msg), .promise = promise });
                self.next_promise += 1;
            },
            .far => |far_ref| try self.farDeliver(far_ref, msg, null),
        }
    }

    /// Clone `msg` into the vat-owned queue arena: the one named boundary copy
    /// of the local eventual-send path, symmetric with the far path's clone
    /// inside `peer.sendCopying`. A queued message must outlive the sender's
    /// turn — the drive that runs it begins by resetting the very turn arena
    /// the documented handler pattern builds outgoing args in — so the queue
    /// owns its bytes. The whole arena resets once, when an outermost `drive`
    /// has fully drained the queue.
    fn cloneForQueue(self: *Vat, msg: Message) Error!Message {
        const arena = self.queue_arena.allocator();
        return .{
            .verb = try arena.dupe(u8, msg.verb),
            .args = try model.cloneArgumentSlice(arena, msg.args),
        };
    }

    /// Encode a far `op:deliver` to a settled far import, the resolved-target
    /// case of `farDeliverTo`.
    fn farDeliver(self: *Vat, far_ref: model.FarRef, msg: Message, answer: ?model.AnswerId) Error!void {
        return self.farDeliverTo(.{ .far = far_ref }, msg, answer);
    }

    /// Encode one far `op:deliver` for `msg` to a wire `target` — a far import
    /// (`farDeliver`) or a pending answer (`sendToAnswer`'s `desc:answer`) —
    /// requesting `answer` (null for a no-answer `tell`). Two named allocations
    /// live here, the one place the far-send path needs them. First, a scratch
    /// slice that splices the verb symbol ahead of the args, because the wire
    /// deliver carries `[verb, args…]` as one list while the actor API keeps the
    /// verb separate — freed immediately (the elements are borrowed, only the
    /// spine is owned). Second, the one boundary clone inside
    /// `peer.sendCopying`, which the outbound queue requires since `msg`'s args
    /// are borrowed from the caller. The splice cannot reuse the clone:
    /// `sendCopying` clones whatever list it is handed, and the verb must be in
    /// that list first.
    fn farDeliverTo(self: *Vat, target: model.Reference, msg: Message, answer: ?model.AnswerId) Error!void {
        const peer = self.peer orelse return Error.NotConnected;
        const has_verb = msg.verb.len > 0;
        const full = try self.allocator.alloc(model.Argument, msg.args.len + @intFromBool(has_verb));
        defer self.allocator.free(full);
        var head: usize = 0;
        if (has_verb) {
            full[0] = .{ .symbol = msg.verb };
            head = 1;
        }
        for (msg.args, 0..) |argument, i| full[head + i] = argument;
        peer.sendCopying(.{ .deliver = .{
            .target = target,
            .args = full,
            .answer = answer,
        } }) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => Error.SendRejected,
        };
    }

    /// Register a one-shot listener for `promise`. A local promise fires during
    /// `drive`; a far promise fires when the partner's resolution arrives and is
    /// dispatched by `serve`. A promise holds at most one listener, so a second
    /// registration before the first fires returns `AlreadyListening` instead
    /// of silently orphaning the first.
    pub fn on(self: *Vat, promise: Promise, listener: Listener) Error!void {
        switch (promise) {
            .local => |id| {
                const gop = try self.listeners.getOrPut(self.allocator, id);
                if (gop.found_existing) return Error.AlreadyListening;
                gop.value_ptr.* = listener;
            },
            .far => |answer| {
                const gop = try self.far_listeners.getOrPut(self.allocator, answer);
                if (gop.found_existing) return Error.AlreadyListening;
                gop.value_ptr.* = listener;
            },
        }
    }

    /// Break every outstanding far promise with `message`, firing each
    /// listener's break path synchronously, before this returns, a
    /// stack-bound listener context is safe because nothing fires later. A far promise settles only when the partner's resolution
    /// arrives over the wire, so once the connection is gone those resolutions can
    /// never come. A driver calls this on disconnect, so an awaiting `on`
    /// listener settles broken instead of waiting forever. `message` is borrowed
    /// for the duration of the calls, so a static string is the norm. Local
    /// promises are untouched: they settle synchronously in `drive` and never
    /// wait on the wire.
    pub fn breakFarPromises(self: *Vat, message: []const u8) void {
        // Drain by removing each entry before firing it: a listener may react by
        // registering another far promise, which would resize the map and
        // invalidate a live iterator. Removing first keeps the map consistent at
        // every callback.
        while (self.far_listeners.count() > 0) {
            var keys = self.far_listeners.keyIterator();
            const answer = keys.next().?.*;
            const entry = self.far_listeners.fetchRemove(answer).?;
            entry.value.func(entry.value.ctx, .{ .broken = message });
        }
    }

    /// Bind an already-spawned local actor to export `position` so a partner's
    /// deliveries to that position run the actor (dispatched by `serve`). Requires
    /// a bound peer. This is the numeric-position primitive; the by-name publish
    /// verb one layer up (`driver.publishNamed`, `ConnectedVat.publish`) rides on
    /// it. Only a local actor can be bound — a far ref already lives elsewhere —
    /// so a far ref returns `NotLocal`.
    pub fn bindExport(self: *Vat, actor: Ref, position: u64) !void {
        const local_id = switch (actor) {
            .local => |a| a,
            .far => return Error.NotLocal,
        };
        const peer = self.peer orelse return Error.NotConnected;
        // Reject a collision before touching the peer: the export → actor map is
        // authority (it decides which local object a partner reaches), so a second
        // bind to the same position fails loud rather than orphaning the first.
        const gop = try self.exports.getOrPut(self.allocator, position);
        if (gop.found_existing) return Error.AlreadyPublished;
        // getOrPut inserted the key with an undefined value; if registering the
        // export fails, drop the half-inserted entry so the map never holds a
        // position the peer doesn't actually export.
        errdefer _ = self.exports.remove(position);
        try peer.exportObject(position);
        gop.value_ptr.* = local_id;
    }

    /// The local `Ref` bound to wire export `position`, or null when no actor is
    /// exported there, the inverse of `bindExport`'s position → actor map. A
    /// surface that receives a near reference (which names an object by its wire
    /// export position, not its vat-local actor id) resolves it through here so a
    /// position is never mistaken for an actor id; `Vat.serve` resolves an inbound
    /// deliver's target the same way.
    pub fn refForExport(self: *const Vat, position: u64) ?Ref {
        const local_id = self.exports.get(position) orelse return null;
        return .{ .local = local_id };
    }

    /// Whether the vat is idle: no turn or drive in flight and no queued sends.
    /// `snapshot` and `restore` require it, so time-travel never captures or
    /// rewinds a half-mutated heap.
    fn quiescent(self: *const Vat) bool {
        return self.turn_depth == 0 and self.drive_depth == 0 and self.queue.items.len == 0;
    }

    /// Capture the local actor heap: share every actor's `StateBox` (refcount up,
    /// no bytes copied, O(objects), Goblins's `snapshot-whactormap` shape) and
    /// the `next_actor` counter. Requires quiescence (`NotQuiescent`) and every
    /// actor to be cloneable or persistent (`NotSnapshottable`); on either failure
    /// nothing is left shared. The returned `Snapshot` is the owner's to `deinit`.
    pub fn snapshot(self: *Vat) Error!Snapshot {
        if (!self.quiescent()) return Error.NotQuiescent;
        var snap = Snapshot{ .allocator = self.allocator };
        errdefer snap.deinit();
        var it = self.actors.iterator();
        while (it.next()) |entry| {
            const box = entry.value_ptr.box;
            if (box.clone == null and !box.persistent) return Error.NotSnapshottable;
            try snap.boxes.put(self.allocator, entry.key_ptr.*, box);
            box.refs += 1;
        }
        snap.next_actor = self.next_actor;
        return snap;
    }

    /// Rewind the local actor heap to `snap`: re-point every actor at the
    /// snapshot's shared boxes and restore `next_actor`. Requires quiescence. The
    /// new table is built (sharing the snapshot's boxes) before the live boxes are
    /// released, so a mid-build failure leaves the live heap intact. `snap` stays
    /// reusable across repeated restores. Touches local actor state only, never
    /// the peer, exports, far listeners, or arenas.
    pub fn restore(self: *Vat, snap: *const Snapshot) Error!void {
        if (!self.quiescent()) return Error.NotQuiescent;
        var rebuilt: std.AutoHashMapUnmanaged(u64, Cell) = .{};
        errdefer {
            var rit = rebuilt.valueIterator();
            while (rit.next()) |cell| releaseBox(self.allocator, cell.box);
            rebuilt.deinit(self.allocator);
        }
        var sit = snap.boxes.iterator();
        while (sit.next()) |entry| {
            try rebuilt.put(self.allocator, entry.key_ptr.*, .{ .box = entry.value_ptr.* });
            entry.value_ptr.*.refs += 1;
        }
        // Commit: the rebuilt table is fully built and ref-counted, so releasing
        // the live boxes and swapping cannot fail.
        var lit = self.actors.valueIterator();
        while (lit.next()) |cell| releaseBox(self.allocator, cell.box);
        self.actors.deinit(self.allocator);
        self.actors = rebuilt;
        self.next_actor = snap.next_actor;
    }

    /// Run queued local eventual-sends to quiescence, settling each promise with
    /// the handler's value (or a break on error) and firing its listener. Turns
    /// queued by a turn run in the same drive (FIFO). The queued messages'
    /// clones live in the queue arena, which resets — capacity retained — only
    /// when the *outermost* drive has fully drained the queue, so a turn that
    /// queues more sends mid-drive never has its message freed under it.
    pub fn drive(self: *Vat) Error!void {
        self.drive_depth += 1;
        defer self.drive_depth -= 1;
        var index: usize = 0;
        while (index < self.queue.items.len) {
            const queued = self.queue.items[index];
            index += 1;
            const resolution: Resolution = if (self.callLocal(queued.target, queued.msg)) |value|
                .{ .fulfilled = value }
            else |err|
                .{ .broken = @errorName(err) };
            try self.settleLocal(queued.promise, resolution);
        }
        self.queue.clearRetainingCapacity();
        if (self.drive_depth == 1) _ = self.queue_arena.reset(.retain_capacity);
    }

    /// Dispatch one inbound peer event: a deliver to a published actor runs its
    /// turn and resolves the answer; a resolve for a far promise fires its
    /// listener. Returns whether the event belonged to this vat; if it did not,
    /// the caller handles it. The application polls the peer and hands events here.
    pub fn serve(self: *Vat, event: *engine.Event) !bool {
        const body = event.view() catch return false;
        switch (body) {
            .deliver => |deliver| {
                const export_position = deliver.target.exportPosition() orelse return false;
                const local_id = self.exports.get(export_position.int()) orelse return false;
                // V1.0: when the deliver has no wire answer but carries a
                // resolve_me_desc, the engine installed a virtual answer for
                // the resolver. Look it up so the resolve reaches the partner.
                const answer = deliver.answer orelse if (self.peer) |peer| blk: {
                    if (deliver.resolve_me_desc) |rmd| {
                        // The resolve-me-desc may arrive as `.far` (original
                        // inbound from the wire) or `.near` (a synthesized
                        // pipelined-drain event that round-tripped through
                        // encode+decode, flipping the perspective). `position`
                        // accepts both — near and far name one integer space.
                        const id = rmd.position() orelse break :blk @as(?model.AnswerId, null);
                        break :blk peer.session_state.answerForResolverImport(model.ImportId.from(id));
                    }
                    break :blk @as(?model.AnswerId, null);
                } else null;
                const reply = reply: {
                    // The depth and actor checks run before the turn opens,
                    // ordered exactly as `callLocal` orders them, so a refusal
                    // never resets the arena.
                    if (self.turn_depth >= max_near_call_depth) {
                        try self.resolveBreak(answer, @errorName(Error.NearCallTooDeep));
                        return true;
                    }
                    const cell = self.actors.getPtr(local_id) orelse {
                        try self.resolveBreak(answer, @errorName(Error.NoSuchActor));
                        return true;
                    };
                    // Copy-on-write a shared box before the inbound turn can
                    // mutate it, ordered with the checks above so a refusal
                    // never resets the arena.
                    try self.ensureUnshared(cell);
                    const box = cell.box;
                    // Materialize the borrowed wire args *inside* the turn
                    // window: `beginTurn`'s depth-0 reset has already run, so
                    // the args land in the turn arena and the next outermost
                    // turn's reset reclaims them — bump-and-reset instead of a
                    // per-event allocate/free walk on the vat allocator. The
                    // handler contract is already turn-scoped (module header),
                    // so nothing may retain them past this window anyway; the
                    // reply (which may alias the args) stays valid until the
                    // next outermost turn, exactly as documented.
                    const arena = self.beginTurn();
                    defer self.endTurn();
                    const args = try deliver.args.toOwnedSlice(arena);
                    var turn = Turn{ .vat = self, .self_ref = .{ .local = local_id }, .arena = arena, .inbound_answer = answer };
                    if (box.handle(box.ptr, &turn, messageFor(args))) |value| {
                        if (turn.pending_become) |pending| self.installBecome(pending);
                        // A forwarding actor handed its answer to another send's
                        // promise; that promise resolves it, not this return.
                        if (turn.forwarded) return true;
                        break :reply value;
                    } else |err| {
                        if (turn.pending_become) |pending| releaseBox(self.allocator, pending.box);
                        try self.resolveBreak(answer, @errorName(err));
                        return true;
                    }
                };
                try self.resolveFulfill(answer, reply);
                return true;
            },
            .resolve => |resolve| {
                const entry = self.far_listeners.fetchRemove(resolve.answer) orelse return false;
                switch (resolve.resolution) {
                    .fulfill => |value| {
                        // Deliberately the vat allocator, not the turn arena: a
                        // listener may legitimately open a top-level turn
                        // (`near` or `drive`) while it runs, and that turn's
                        // depth-0 arena reset would free this value mid-call.
                        // It is one argument freed right here, not a per-event
                        // slice walk.
                        const owned = try value.toOwned(self.allocator);
                        defer model.freeArgument(self.allocator, owned);
                        entry.value.func(entry.value.ctx, .{ .fulfilled = owned });
                    },
                    .@"break" => |reason| entry.value.func(entry.value.ctx, .{ .broken = reason.message }),
                }
                return true;
            },
            else => return false,
        }
    }

    /// Fire `promise_id`'s listener, if any. A fulfilled value lives in the
    /// turn arena (or aliases the queued message), and a listener may
    /// legitimately open a top-level turn (`near` or `drive`) while it runs,
    /// whose depth-0 reset would free that storage mid-call. So the one
    /// argument is cloned onto the vat allocator for the duration of the
    /// listener call and freed right here, mirroring the far-resolve path in
    /// `serve`. A broken resolution carries `@errorName`'s static string, which
    /// no reset can free.
    fn settleLocal(self: *Vat, promise_id: u64, resolution: Resolution) Error!void {
        const entry = self.listeners.fetchRemove(promise_id) orelse return;
        switch (resolution) {
            .fulfilled => |value| {
                const owned = try model.cloneArgument(self.allocator, value);
                defer model.freeArgument(self.allocator, owned);
                entry.value.func(entry.value.ctx, .{ .fulfilled = owned });
            },
            .broken => entry.value.func(entry.value.ctx, resolution),
        }
    }

    fn resolveFulfill(self: *Vat, answer: ?model.AnswerId, reply: model.Argument) !void {
        const ans = answer orelse return;
        const peer = self.peer orelse return;
        try peer.sendCopying(.{ .resolve = .{ .answer = ans, .resolution = .{ .fulfill = reply } } });
    }

    fn resolveBreak(self: *Vat, answer: ?model.AnswerId, message: []const u8) !void {
        const ans = answer orelse return;
        const peer = self.peer orelse return;
        try peer.sendCopying(.{ .resolve = .{ .answer = ans, .resolution = .{ .@"break" = .{ .message = message } } } });
    }
};

/// Split an inbound deliver's args into a method verb and its arguments: a
/// leading symbol is the verb, the rest are its arguments. This is the inverse of
/// what `Vat.send` does on the way out (it prepends the verb as a leading
/// symbol), so a pancake actor talking to a pancake actor round-trips exactly.
///
/// It is a convention of this actor layer, not an OCapN rule: OCapN delivers a
/// positional argument list with no distinguished method slot. So a deliver from
/// a peer that does not follow the convention — a genuine Goblins object whose
/// first real argument is itself a symbol, or a call sent with no leading verb —
/// is read here as "the first symbol is the method." A vat hosting objects for a
/// non-pancake peer must agree on this verb-as-leading-symbol convention, or
/// dispatch by inspecting the args directly rather than through this split.
fn messageFor(args: []const model.Argument) Message {
    if (args.len > 0 and args[0] == .symbol) {
        return .{ .verb = args[0].symbol, .args = args[1..] };
    }
    return .{ .verb = "", .args = args };
}
