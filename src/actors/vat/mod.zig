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
//! expressed through Zig's ordinary mutable state. A mutable actor's turn is
//! not transactional: `self` mutations are not rolled back on a handler error —
//! the caller still sees the break, but writes made before the failure persist.
//! Use the persistent flavor for all-or-nothing turns; its staged `become` is
//! discarded when the handler errors.
//!
//! Ownership at the handler boundary is *turn-scoped*. The `Message` a handler
//! receives borrows its arguments for the duration of the turn. For its reply a
//! handler has three choices, and the vat reclaims storage after each. It
//! can return a value owned by its own `self` or aliased from the message, which
//! allocates nothing. It can allocate the reply and any scratch from
//! `turn.arena`, the per-turn allocator the vat hands every handler. The vat owns
//! that arena and resets it when its next top-level turn begins, so a handler
//! never frees its own reply and never leaks one. Or a mutable handler can
//! *transfer* an owned byte field to the vat with `turn.moveOut`, an O(1)
//! hand-off where copying the buffer onto the arena would be O(len); the vat
//! then owns the bytes and frees them on the same schedule as the arena. In
//! every case the reply is valid until the vat's next top-level turn: within
//! that window the vat clones it for the local vow's listener or clones it
//! onto the wire (the one clone in `peer.sendCopying`). To keep a value beyond
//! your turn, store it in `self` or copy it; never return storage that ends
//! before the turn does. A `Resolution` delivered to a listener follows the
//! same rule. It is valid only for that listener call, so a listener that keeps
//! it copies first.
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
//!     the bound peer. Either way it returns a `Vow` you observe with
//!     `Vat.on`.
//!
//! A `Vow` is observed with `Vat.on` and has no matching `off`. A listener fires
//! exactly once, when the vow settles or when `breakFarVows` breaks every far vow
//! on disconnect, so there is nothing to cancel: dropping interest before a settle
//! is the break path's job, not a listener removal. An `off(vow)` handle is the
//! shape to add if a real timeout-or-cancel consumer ever wants one; none does
//! today.
//!
//! The unified `Ref` can name a local actor or a far object, and a `Vow`
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
//!     @This(), allocator) std.mem.Allocator.Error!@This()` keeps mutating its
//!     `self` and is copied-on-write: the vat deep-clones a *shared* box before the
//!     next turn can mutate it, so the snapshot's copy is never touched. `clone`
//!     returns the next state *by value*; the vat moves it into the fresh state
//!     block it allocates, so a clone is one allocation plus whatever heap the
//!     state itself dupes.
//!   * **Persistent + `become`.** An actor that declares `pub const
//!     snapshot_persistent = true;` never mutates `self`; it produces its next
//!     state with `Turn.become`. Its `handle` receives `self: *const @This()`, so
//!     an accidental `self.field = x` fails to compile rather than writing through
//!     the pointer a live snapshot shares (shallow immutability: an interior
//!     pointer the actor owns is still its own to keep unmutated). Because the
//!     value is never mutated in place, the snapshot shares it with no
//!     copy-on-write — full Goblins parity.
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

const boxed = @import("boxed.zig");
const serve_mod = @import("serve.zig");
const turn_mod = @import("turn.zig");

/// The per-turn handler context (see `turn.Turn`).
pub const Turn = turn_mod.Turn;

// The vat's steady footprint bounds, one per reclaim site, mirroring the
// engine's `steady_queue_bytes` posture (src/ocapn/engine/mod.zig): at
// one-vat-per-connection scale, capacity a burst grew must not stay
// pinned for the connection's life — capacity at or under the bound is
// retained so steady turns stay allocation-free, capacity above it is
// freed at the same drain boundary that used to retain it. The named
// trade is one growth re-allocation at the start of the *next* burst
// episode, never per turn — the same trade the engine documents, and why
// `retain_with_limit` beats `free_all`. Recorded in
// .agents/rules/memory.md's per-session footprint budget. File-level (not
// `Vat` decls) so the sibling vat modules share them without widening the
// public surface.
/// Turn-arena bound, applied at the outermost-turn reset in `turn.beginTurn`.
pub const steady_turn_arena_bytes = 4096;
/// Queue-arena bound, applied at the outermost drive's full-drain reset.
pub const steady_queue_arena_bytes = 4096;
/// Settle-arena bound, applied at the depth-0 reset in the far-resolve settle.
pub const steady_settle_arena_bytes = 4096;
/// Backing bound for the plain ArrayLists (`queue`, `moved_replies`):
/// above it the drain point does `clearAndFree` instead of retaining,
/// the engine `Queue.pop` idiom.
pub const steady_list_bytes = 4096;
/// Cap on `served_dropped_far`: the count of resolve-before-`on` drops the
/// vat remembers to refuse a late `on`. Empty in the normal flow; the cap
/// bounds a pathological stream of unclaimed drops (past it a late `on`
/// parks, as before the guard).
pub const max_served_dropped_far_answers = 256;

const Cell = boxed.Cell;
const PendingBecome = boxed.PendingBecome;
const StateBox = boxed.StateBox;
const releaseBox = boxed.releaseBox;
/// A captured local actor heap (see `boxed.Snapshot`).
pub const Snapshot = boxed.Snapshot;

/// A reference the vat can eventual-send to, wherever the object lives.
pub const Ref = union(enum) {
    /// An actor in this vat. `near` and `send` run its turns here.
    local: u64,
    /// A partner-hosted object the bound peer holds as an import. `send` routes
    /// to it as an `op:deliver`; `near` is illegal.
    far: model.FarRef,
};

/// A handle to the eventual result of a `Vat.send` — the vow of E/Goblins:
/// unsettled until the turn runs or the partner resolves, observed with
/// `Vat.on`.
pub const Vow = union(enum) {
    /// Result of a local send; settled by `Vat.drive`.
    local: u64,
    /// Result of a far send; the outbound answer position the partner resolves.
    far: model.AnswerPosition,
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

/// How a vow settled. The carried value (`fulfilled` argument or `broken`
/// message) is borrowed only for the duration of the listener call. A listener
/// that retains it copies first.
pub const Resolution = union(enum) {
    fulfilled: model.Argument,
    broken: []const u8,
    /// The vow fulfilled with a three-party introduction: a signed
    /// `desc:handoff-give` the holder redeems (dial the exporter, withdraw)
    /// before the capability is usable. A host tier claims and redeems every
    /// give itself, so this arm surfaces only below it, on the
    /// single-session surfaces. Like `fulfilled`, the payload is borrowed
    /// for the listener call.
    give: Give,
};

/// A settlement a host tier feeds `Vat.settleFar`: the two arms a redeemed
/// world can carry. It is `Resolution` minus `give` — the executor above the
/// vat redeems every give before the vat sees one, and this type holds that
/// contract structurally. The payload is borrowed for the listener call,
/// exactly as `Resolution`'s is.
pub const FarOutcome = union(enum) {
    fulfilled: model.Argument,
    broken: []const u8,
};

/// A projected three-party introduction, built where the wire event is still
/// in hand so the verbatim signed envelope survives (a decoded argument alone
/// cannot recover it).
pub const Give = struct {
    /// The verbatim signed `desc:handoff-give` envelope, relayed unaltered to
    /// the exporter inside the recipient's `desc:handoff-receive`.
    give_bytes: []const u8,
    /// The give's exporter location as a dialable `ocapn://…` URI, or empty
    /// when the location is not dialable.
    exporter_locator_uri: []const u8,
    /// The recipient session key the give is addressed to; the withdraw must
    /// sign with its secret half.
    recipient_key: []const u8,
};

/// What a `ResolveInterceptor` decided about a served reply. A two-arm union
/// so the common pass-through is spelled, never the accidental value of an
/// optional.
pub const InterceptOutcome = union(enum) {
    /// The interceptor owns resolving the answer by other means; the vat sends
    /// nothing.
    claimed,
    /// Resolve with this argument (the original `fulfilled` pass-through, or a
    /// rewrite). Turn-borrowed, same window as a handler's reply.
    resolve: model.Argument,
};

/// A served reply's interceptor: fires before the vat resolves an inbound
/// answer with a fulfilled value, and decides what the vat resolves with.
/// This is the seam a handoff-originating host installs: a reply that
/// fulfills with a capability homed on another connection becomes a signed
/// give (`.claimed` — the vat sends nothing), and a node-local routing token
/// is rewritten to the real wire reference so it never reaches the wire
/// (ADR-0067/0069). It adds no semantics a plain resolve lacks. A returned
/// `.resolve` value is turn-borrowed, exactly like a handler's own reply; a
/// rewrite must stay valid for that same window.
pub const ResolveInterceptor = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, answer: model.AnswerPosition, fulfilled: model.Argument) anyerror!InterceptOutcome,
};

/// A one-shot vow listener: `func(ctx, resolution)` fires when the vow
/// settles. `ctx` is the caller's opaque state (or null).
pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, resolution: Resolution) void,
};

/// A *hosted* actor: state and behavior the vat does not own, invoked on each
/// deliver (ADR-0071). This is how a non-Zig consumer hosts an actor over the C
/// ABI — it hands the vat an opaque `ctx` and a thunk. The `handle` receives the
/// full `Turn`, so a hosted actor sends and spawns exactly like a native one;
/// only vat-owned time-travel is out of reach, since the vat cannot clone `ctx`
/// (a vat holding a hosted actor is not snapshottable, `NotSnapshottable`).
pub const HostedActor = struct {
    /// The consumer's state, opaque to the vat, passed back to `handle`/`free`.
    ctx: *anyopaque,
    /// Invoked on each deliver. Returns the reply — borrowed for the turn, the
    /// vat clones it onto the wire or a listener — or an error (settled broken).
    handle: *const fn (ctx: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument,
    /// Release `ctx` when the actor's box drops (vat `deinit`, or a failed
    /// spawn). Null when the consumer keeps ownership of `ctx`.
    free: ?*const fn (ctx: *anyopaque) void = null,
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
    /// `Vat.on` was called for a vow that already holds a listener.
    /// Listeners are one-shot and a vow holds at most one, so replacing it
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
    /// `Vat.on` was called for a local vow that already settled (a prior
    /// `drive` ran its turn). Local vows settle exactly once, in FIFO
    /// order, so a listener registered afterwards could never fire; failing
    /// loud beats parking it forever.
    AlreadySettled,
    /// A local value tree deep-copied into the queue or a settle nested past
    /// `model.max_value_depth`. Copying an actor's arguments walks the tree
    /// recursively, so the model-layer depth ceiling caps that walk here too,
    /// failing loud rather than overflowing the native stack. Real handler
    /// arguments never reach it; a pathologically nested local value does.
    MalformedView,
} || std.mem.Allocator.Error;

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
    resolve_interceptor: ?ResolveInterceptor = null,
    actors: std.AutoHashMapUnmanaged(u64, Cell) = .{},
    queue: std.ArrayList(Queued) = .empty,
    /// The drain cursor into `queue`, shared across nested drives so a listener
    /// that opens a re-entrant drive continues where the outer left off instead
    /// of re-running already-executed turns. Only the outermost drive resets it.
    queue_head: usize = 0,
    listeners: std.AutoHashMapUnmanaged(u64, Listener) = .{},
    /// Listener for a far send's vow, keyed by outbound answer position.
    far_listeners: std.AutoHashMapUnmanaged(model.AnswerPosition, Listener) = .{},
    /// Outbound answers whose resolve was *served* before any listener was
    /// registered, so `serve` had to drop it. `on`'s far arm reads this to
    /// refuse a late listener with `AlreadySettled` — the wire mirror of the
    /// local settled guard — rather than park an awaiter that can never fire.
    /// Empty in the ordinary send-then-`on`-then-serve flow, so an idle
    /// connection holds nothing here; capped at `max_served_dropped_far_answers`
    /// so a stream of unclaimed drops cannot grow it without bound (past the cap
    /// a late `on` falls back to parking, the pre-guard behavior). An entry is
    /// removed when a late `on` claims it, and the whole set frees at `deinit`.
    served_dropped_far: std.AutoHashMapUnmanaged(model.AnswerPosition, void) = .{},
    /// Local actor id for each export position published on the peer.
    exports: std.AutoHashMapUnmanaged(u64, u64) = .{},
    // The three arenas below (turn, queue, settle) retain their backing storage
    // across a reset, and a safety build does not poison that retained region.
    // The use-after-reset class is closed at the root instead: each value that
    // must outlive a reset is cloned clear of it (see `settleLocal` and the
    // become-in-turn reply), and the scribble tests overwrite the arena to catch
    // a stale borrow. A blanket poison-on-reset detector is not added because
    // `std.heap.ArenaAllocator` retains its buffer with no poison hook and a
    // private node type, so a correct one would need fragile internals or a
    // bespoke arena, both disproportionate to a debug-only aid.
    /// Per-turn scratch the vat hands each handler as `turn.arena`. A handler's
    /// reply and scratch live here; the vat reclaims the whole arena when its next
    /// outermost turn begins (when `turn_depth` returns to 0 and rises again), so a
    /// reply stays valid until then and no handler frees or leaks its own reply.
    turn_arena: std.heap.ArenaAllocator,
    /// Owns every queued local eventual-send's message clone. A queued turn runs
    /// at the next `drive`, after the turn arena the sender built its args in has
    /// been reset, so the queue cannot borrow them: `send`/`tell` clone the
    /// message here, and one bounded reset (`retain_with_limit`, see the
    /// steady-bytes constants below) reclaims everything when the outermost
    /// `drive` has fully drained the queue. That reset condition is
    /// drive-to-quiescence, so an unbounded self-send chain makes the outermost
    /// `drive` never return. A loop host runs `driveBudgeted` instead: it drains
    /// each inbound batch to quiescence (so this arena resets every batch) but
    /// caps the turns at `max_batch_local_turns`, closing a connection whose one
    /// batch amplifies past the cap rather than letting this arena grow across
    /// an unbounded drain. The connection-per-thread `drive` stays unbounded by
    /// contract.
    queue_arena: std.heap.ArenaAllocator,
    /// Nesting depth of in-flight turns. The turn arena resets only at depth 0, so a
    /// near-call or send made inside a turn shares that turn's scratch rather than
    /// pulling it out from under the call in flight.
    turn_depth: u32 = 0,
    /// Nesting depth of in-flight `drive` calls. A listener may open a nested
    /// `drive`; only the outermost one may reset the queue arena, or the inner
    /// reset would free messages the outer drive still holds.
    drive_depth: u32 = 0,
    /// Scratch for the far-resolve settle in `serve`: an inbound fulfilled
    /// value is cloned here for its listener call. The queue arena is not safe
    /// for that clone — `serve` runs outside any drive, so a listener-opened
    /// `drive` is *outermost* and its full-drain reset would free the value
    /// mid-call. This arena resets only when `settle_depth` returns to zero.
    settle_arena: std.heap.ArenaAllocator,
    /// Nesting depth of in-flight far-resolve settles. A far listener can
    /// re-enter `serve` (a driver pump: `BlockingSession.step` then `drainEvents`),
    /// and the nested settle must not reset the arena the outer listener's
    /// value still lives in; only the return to depth 0 resets it.
    settle_depth: u32 = 0,
    next_actor: u64 = 1,
    next_vow: u64 = 1,
    /// The highest local vow id already settled by `drive`. Local vows
    /// settle in FIFO order (ids are monotonic), so `on`'s local arm can refuse
    /// a registration for `id <= last_settled_vow` with `AlreadySettled`
    /// rather than parking a listener that can never fire.
    last_settled_vow: u64 = 0,
    /// Reply bytes handlers moved to the vat via `Turn.moveOut`, awaiting free.
    /// They share the turn arena's lifetime: the vat frees them when its next
    /// outermost turn begins, so a moved reply stays valid for the caller until
    /// then — with no copy, since the handler already owned the bytes.
    moved_replies: std.ArrayList([]const u8) = .empty,

    const Queued = struct { target: u64, msg: Message, vow: u64 };

    /// A pure-local vat (no wire). `near`/`send`/`drive` over local actors only.
    pub fn init(allocator: std.mem.Allocator) Vat {
        return .{
            .allocator = allocator,
            .turn_arena = std.heap.ArenaAllocator.init(allocator),
            .queue_arena = std.heap.ArenaAllocator.init(allocator),
            .settle_arena = std.heap.ArenaAllocator.init(allocator),
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
            .settle_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Vat) void {
        var it = self.actors.valueIterator();
        while (it.next()) |cell| {
            // A become promoted by the last frame but never installed (a vat torn
            // down mid-run) still owns its box.
            if (cell.pending_become) |box| releaseBox(self.allocator, box);
            releaseBox(self.allocator, cell.box);
        }
        self.actors.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        // Reclaim only the listener contexts the vat itself allocated, keyed by
        // function-pointer identity: a local `forward` heap-allocates a
        // `ForwardContext` whose only free path is the listener firing, which a
        // never-drained queue at teardown skips. Every other listener context is
        // caller-owned (an `on` caller's stack state), so it must be left alone.
        self.freeOwnedForwardContexts(&self.listeners);
        self.freeOwnedForwardContexts(&self.far_listeners);
        self.listeners.deinit(self.allocator);
        self.far_listeners.deinit(self.allocator);
        self.served_dropped_far.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        turn_mod.drainMovedReplies(self);
        self.moved_replies.deinit(self.allocator);
        self.turn_arena.deinit();
        self.queue_arena.deinit();
        self.settle_arena.deinit();
    }

    /// Free the vat-owned `ForwardContext` behind every `forwardListener` entry
    /// in `map`, identified by function-pointer identity so caller-owned listener
    /// contexts are never touched. A fired listener removes its entry, so only
    /// unfired forwards remain here, making a double-free impossible.
    fn freeOwnedForwardContexts(self: *Vat, map: anytype) void {
        var it = map.valueIterator();
        while (it.next()) |listener| {
            if (listener.func == serve_mod.forwardListener) {
                const fc: *serve_mod.ForwardContext = @ptrCast(@alignCast(listener.ctx.?));
                self.allocator.destroy(fc);
            }
        }
    }

    /// Spawn a local actor with `initial` state, returning a local `Ref`. No
    /// export position is minted: the actor has no wire position at all until
    /// it is bound with `bindExport` (or spawned through the driver's
    /// exporting `spawn`), and even a bound position stays unaddressable
    /// until its reference first marshals onto the wire. `initial` is
    /// consumed on every outcome: on failure its resources are reclaimed
    /// through the state's `deinit`, so the caller never frees it.
    pub fn spawn(self: *Vat, comptime Behavior: type, initial: Behavior) Error!Ref {
        const box = try boxed.makeBox(self, Behavior, initial);
        errdefer releaseBox(self.allocator, box);

        const id = self.next_actor;
        try self.actors.put(self.allocator, id, .{ .box = box });
        self.next_actor += 1;
        return .{ .local = id };
    }

    /// Spawn a *hosted* actor (ADR-0071): its state and behavior live outside
    /// the vat, behind `hosted.ctx`, reached through the callbacks in
    /// `HostedActor`. This is the C-ABI hosting path a non-Zig consumer uses;
    /// the actor is otherwise ordinary — it is delivered to, driven, sent to,
    /// and listened on exactly like a native one, and its `handle` gets the full
    /// `Turn`. Like `spawn`, mints no export (bind it with `bindExport` to reach
    /// it). `hosted.free`, if set, runs on every outcome — including a failed
    /// spawn, which frees `ctx` before returning the error — so the caller never
    /// double-frees. The box carries no `clone`, so a vat holding a hosted actor
    /// is not snapshottable (`snapshot` returns `NotSnapshottable`).
    pub fn spawnHosted(self: *Vat, hosted: HostedActor) Error!Ref {
        const box = try boxed.makeHostedBox(self, hosted);
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
            .local => |id| turn_mod.callLocal(self, id, msg),
            .far => Error.NotNearCallable,
        };
    }

    /// The eventual send (`<-`): location-transparent. A local target queues a
    /// turn for `drive`; a far target sends an `op:deliver` over the bound peer
    /// (a leading symbol carries the verb, matching Goblins's `($ obj 'method …)`).
    /// Returns a `Vow` for the result. The message's verb and args are
    /// borrowed only for the duration of this call: the local arm clones them
    /// into the vat's queue arena, the far arm clones them inside
    /// `peer.sendCopying`.
    pub fn send(self: *Vat, target: Ref, msg: Message) Error!Vow {
        switch (target) {
            .local => |id| return .{ .local = try self.enqueueLocal(id, msg) },
            .far => |far_ref| {
                const peer = self.peer orelse return Error.NotConnected;
                const answer = model.AnswerPosition.from(peer.allocateAnswer());
                try self.farDeliver(far_ref, msg, answer);
                return .{ .far = answer };
            },
        }
    }

    /// Promise pipelining (the questioner half of ADR-0007): eventual-send `msg`
    /// to a far answer this vat is still awaiting — the `.far` position a prior
    /// `send` returned — instead of a settled reference. It puts one
    /// `op:deliver` against `<desc:answer answer_pos>` on the wire, so a
    /// dependent call need not wait for the answer it depends on to come back:
    /// send `create`, then `sendToAnswer(create_answer, assign)` before
    /// `create` resolves. The partner queues the call on that pending answer and
    /// drains it when the answer settles (the serving side ADR-0007 already
    /// built). Returns a `Vow` for this call's own result, which can itself
    /// be pipelined against. `msg`'s verb and args are borrowed only for this
    /// call (cloned inside `peer.sendCopying`). `NotConnected` if no peer is
    /// bound. The empty-path target rides the engine's flat `desc:answer` send;
    /// a multi-hop path is the engine's decomposition concern, not this surface.
    pub fn sendToAnswer(self: *Vat, answer_pos: model.AnswerPosition, msg: Message) Error!Vow {
        const peer = self.peer orelse return Error.NotConnected;
        const answer = model.AnswerPosition.from(peer.allocateAnswer());
        try self.farDeliverTo(.{ .promise = .{ .answer_position = answer_pos } }, msg, answer);
        return .{ .far = answer };
    }

    /// The fire-and-forget eventual-send (Goblins `<-np`): like `send`, but it
    /// requests no answer, so the partner's actor runs and sends no reply. A far
    /// `tell` puts one `op:deliver` with no answer on the wire. That is the
    /// right shape for a notification or broadcast, which would otherwise pay for
    /// a reply nobody reads. A local `tell` queues a turn whose result is
    /// discarded. Returns nothing: there is no vow to observe.
    pub fn tell(self: *Vat, target: Ref, msg: Message) Error!void {
        switch (target) {
            // Queue a turn like `send`, but discard the vow id: it keeps the
            // queue entry uniform and `drive` settles it into no listener.
            .local => |id| _ = try self.enqueueLocal(id, msg),
            .far => |far_ref| try self.farDeliver(far_ref, msg, null),
        }
    }

    /// The one local-enqueue spine `send` and `tell` share: mint the next vow
    /// id, clone the message into the queue arena, and append the turn.
    fn enqueueLocal(self: *Vat, id: u64, msg: Message) Error!u64 {
        const vow = self.next_vow;
        try self.queue.append(self.allocator, .{ .target = id, .msg = try self.cloneForQueue(msg), .vow = vow });
        self.next_vow += 1;
        return vow;
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
    fn farDeliver(self: *Vat, far_ref: model.FarRef, msg: Message, answer: ?model.AnswerPosition) Error!void {
        return self.farDeliverTo(.{ .far = far_ref }, msg, answer);
    }

    /// Encode one far `op:deliver` for `msg` to a wire `target` — a far import
    /// (`farDeliver`) or a pending answer (`sendToAnswer`'s `desc:answer`) —
    /// requesting `answer` (null for a no-answer `tell`). The one named heap
    /// allocation here is the boundary clone inside `peer.sendCopying`, which
    /// the outbound queue requires since `msg`'s args are borrowed from the
    /// caller. The verb splice — the wire deliver carries `[verb, args…]` as
    /// one list while the actor API keeps the verb separate — needs only a
    /// scratch spine whose elements are borrowed and whose lifetime ends when
    /// `sendCopying` returns, so the common arity (verb + up to 7 args) rides
    /// a stack buffer and only a wider call falls back to a gpa slice, freed
    /// immediately. Never the turn arena: this path is callable at depth 0,
    /// where an arena bump would pin until the next outermost turn. The splice
    /// cannot reuse the clone: `sendCopying` clones whatever list it is
    /// handed, and the verb must be in that list first.
    fn farDeliverTo(self: *Vat, target: model.Reference, msg: Message, answer: ?model.AnswerPosition) Error!void {
        const peer = self.peer orelse return Error.NotConnected;
        const has_verb = msg.verb.len > 0;
        const total = msg.args.len + @intFromBool(has_verb);
        // Verb-splice scratch: stack for the common arity, gpa above it.
        var buf: [8]model.Argument = undefined;
        const full = if (total <= buf.len)
            buf[0..total]
        else
            try self.allocator.alloc(model.Argument, total);
        defer if (total > buf.len) self.allocator.free(full);
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

    /// Register a one-shot listener for `vow`. A local vow fires during
    /// `drive`; a far vow fires when the partner's resolution arrives and is
    /// dispatched by `serve`. A vow holds at most one listener, so a second
    /// registration before the first fires returns `AlreadyListening` instead
    /// of silently orphaning the first.
    pub fn on(self: *Vat, vow: Vow, listener: Listener) Error!void {
        switch (vow) {
            .local => |id| {
                // A local vow settles exactly once, during `drive`; a
                // listener registered after that settlement would never fire,
                // so refuse it loud.
                if (id <= self.last_settled_vow) return Error.AlreadySettled;
                const gop = try self.listeners.getOrPut(self.allocator, id);
                if (gop.found_existing) return Error.AlreadyListening;
                gop.value_ptr.* = listener;
            },
            .far => |answer| {
                // The wire-side mirror of the local guard: if this vow's resolve
                // was already served with no listener to catch it, `serve` dropped
                // it, so a listener registered now would never fire. Refuse it
                // loud rather than park an awaiter that strands forever. A resolve
                // merely applied but not yet served is fine — the app may poll the
                // event, register `on`, then serve to fire it — so the signal is
                // the served-drop, not the session's settled status. The marker is
                // read, never consumed: a retried `on` must hit the same refusal,
                // not slip past it into a listener that can never fire. The set is
                // bounded (`max_served_dropped_far_answers`) and freed at deinit,
                // so retention costs nothing.
                if (self.served_dropped_far.contains(answer)) return Error.AlreadySettled;
                const gop = try self.far_listeners.getOrPut(self.allocator, answer);
                if (gop.found_existing) return Error.AlreadyListening;
                gop.value_ptr.* = listener;
            },
        }
    }

    /// Capture the local actor heap (see `boxed.snapshot`).
    pub const snapshot = boxed.snapshot;
    /// Rewind the local actor heap to a snapshot (see `boxed.restore`).
    pub const restore = boxed.restore;

    /// Dispatch one inbound peer event (see `serve.serve`).
    pub const serve = serve_mod.serve;
    /// Settle a far vow off the wire path (see `serve.settleFar`).
    pub const settleFar = serve_mod.settleFar;
    /// Break every outstanding far vow on disconnect (see `serve.breakFarVows`).
    pub const breakFarVows = serve_mod.breakFarVows;
    /// Bind a local actor to a wire export position (see `serve.bindExport`).
    pub const bindExport = serve_mod.bindExport;
    /// The local ref bound to a wire export, if any (see `serve.refForExport`).
    pub const refForExport = serve_mod.refForExport;

    /// The most local eventual-send turns one inbound batch may drive on a loop
    /// host before the vat is treated as a runaway. A handler's local work
    /// settles in one batch — a legitimate fan-out or chain is far under this —
    /// so the loop drives each batch's queue to completion and reclaims it,
    /// keeping no cross-batch residual and no unbounded queue-arena growth. A
    /// single inbound message that amplifies past this many local turns (a
    /// runaway self-send loop, or an oversized fan-out) exceeds the limit, and
    /// the loop closes that connection rather than stall the residual or hold it
    /// in memory. It is a resource limit like the session's, sized generously.
    /// The connection-per-thread `BlockingSession` serves one partner, so it keeps
    /// the unbounded `drive`. This is the default the TCP and iroh loop hosts'
    /// `Options.max_batch_local_turns` initializes to; an operator raises it per
    /// host for a server whose one message legitimately fans out further, and a
    /// remote peer never sets it (it is the server's own amplification guard).
    pub const max_batch_local_turns: usize = 4096;

    /// The outcome of a budgeted drive: whether the local queue emptied.
    pub const DriveProgress = enum {
        /// The queue drained fully within the budget; its arena was reclaimed,
        /// exactly as `drive`.
        drained,
        /// The budget was spent with turns still queued. Nothing was reset: the
        /// queue and its arena stay intact, and the next `driveBudgeted` resumes
        /// at the same cursor.
        more_pending,
    };

    /// Run queued local eventual-sends to quiescence, settling each vow with
    /// the handler's value (or a break on error) and firing its listener. Turns
    /// queued by a turn run in the same drive (FIFO). The queued messages'
    /// clones live in the queue arena, which resets — capacity retained — only
    /// when the *outermost* drive has fully drained the queue, so a turn that
    /// queues more sends mid-drive never has its message freed under it.
    pub fn drive(self: *Vat) Error!void {
        _ = try self.driveBudgeted(std.math.maxInt(usize));
    }

    /// Like `drive`, but runs at most `max_turns` queued local turns, then
    /// yields `.more_pending` with the queue and cursor left intact (a later
    /// call resumes where it stopped). A vat whose handlers re-send to
    /// themselves without bound makes `drive` never return; on a loop host
    /// that would starve every other connection the loop serves. `driveBudgeted`
    /// gives the loop host a bound to act on: it drives each inbound batch to
    /// `.drained` and treats `.more_pending` as a runaway amplification, closing
    /// that connection (see `max_batch_local_turns`). The connection-per-thread
    /// `BlockingSession` keeps the unbounded `drive` by contract: it serves one
    /// partner, so a self-send chain there starves only itself.
    ///
    /// Call this at the top level (the loop host's per-connection drive point),
    /// not re-entrantly: like `drive`, it shares the vat's queue cursor, and a
    /// nested full `drive` a listener opens runs to quiescence by its own
    /// contract, draining past this budget.
    pub fn driveBudgeted(self: *Vat, max_turns: usize) Error!DriveProgress {
        // A *finite* budget must not nest (the documented contract above): a
        // nested full `drive` (a listener's) is legal and runs unbudgeted.
        std.debug.assert(max_turns == std.math.maxInt(usize) or self.drive_depth == 0);
        self.drive_depth += 1;
        defer self.drive_depth -= 1;
        // The cursor lives on the vat, not the stack: a listener firing inside
        // `settleLocal` may open a nested drive, and it must continue past the
        // turns already run rather than restart at zero and execute them twice.
        // Across budget slices it plays the same role: a yielded slice leaves
        // the cursor where it stopped so the next call resumes there.
        var ran: usize = 0;
        while (ran < max_turns and self.queue_head < self.queue.items.len) {
            const queued = self.queue.items[self.queue_head];
            self.queue_head += 1;
            ran += 1;
            const resolution: Resolution = if (turn_mod.callLocal(self, queued.target, queued.msg)) |value|
                .{ .fulfilled = value }
            else |err|
                .{ .broken = @errorName(err) };
            try self.settleLocal(queued.vow, resolution);
        }
        const drained = self.queue_head >= self.queue.items.len;
        // Only the outermost drive that actually emptied the queue reclaims its
        // arena; a nested drive leaves both for the outer to finish, and a
        // budget-yield with turns still queued must leave the queue and its
        // arena intact — the pending messages' clones live in that arena.
        if (self.drive_depth == 1 and drained) {
            self.queue.clearRetainingCapacity();
            if (self.queue.capacity * @sizeOf(Queued) > steady_list_bytes) {
                self.queue.clearAndFree(self.allocator);
            }
            self.queue_head = 0;
            _ = self.queue_arena.reset(.{ .retain_with_limit = steady_queue_arena_bytes });
        }
        return if (drained) .drained else .more_pending;
    }

    /// Fire `vow_id`'s listener, if any. The clone below defends two
    /// hazards, so it can be re-homed but never deleted. First, a fulfilled
    /// value lives in the turn arena (or aliases the queued message), and a
    /// listener may legitimately open a top-level turn (`near` or `drive`)
    /// while it runs, whose depth-0 reset would free that storage mid-call.
    /// Second, the value may borrow the settling actor's own mutable state,
    /// and a listener-opened nested drive can run a turn that mutates or
    /// `become`-frees that state under the borrow. So the one argument is
    /// cloned into the vat's queue arena: `settleLocal` runs only inside
    /// `drive` (`drive_depth >= 1`), and that arena resets only when the
    /// *outermost* drive has fully drained — which cannot happen while this
    /// listener is still on the outermost drive's stack — so the clone
    /// outlives the listener call with no gpa traffic and no per-settle free.
    /// A broken resolution carries `@errorName`'s static string, which no
    /// reset can free.
    fn settleLocal(self: *Vat, vow_id: u64, resolution: Resolution) Error!void {
        // The queue-arena clone below is safe only inside a drive (see the doc
        // comment); hold that invariant mechanically, not just in prose.
        std.debug.assert(self.drive_depth >= 1);
        // Record the settlement before anything fallible: local vows
        // settle in FIFO order (ids are monotonic), so this high-water mark is
        // what lets `on` refuse a registration that can never fire.
        self.last_settled_vow = vow_id;
        // Peek the listener rather than remove it, mirroring the far-resolve
        // arm in `serve`: the fulfilled arm clones fallibly before firing, and
        // an OOM return must leave the entry in the map so teardown
        // (`freeOwnedForwardContexts`) still reclaims a forward's heap
        // context. Each arm removes the entry immediately before it fires,
        // preserving the remove-before-fire order a listener that re-registers
        // the vow relies on.
        const listener = self.listeners.get(vow_id) orelse return;
        switch (resolution) {
            .fulfilled => |value| {
                const owned = try model.cloneArgument(self.queue_arena.allocator(), value);
                std.debug.assert(self.listeners.fetchRemove(vow_id) != null);
                listener.func(listener.ctx, .{ .fulfilled = owned });
            },
            .broken => {
                std.debug.assert(self.listeners.fetchRemove(vow_id) != null);
                listener.func(listener.ctx, resolution);
            },
            // Local settlement never carries a wire introduction; only the
            // far-resolve path in `serve` constructs `.give`.
            .give => unreachable,
        }
    }

    /// Install (or clear, with null) the served-reply interceptor. One per
    /// vat: the host that owns cross-connection routing is the only consumer.
    pub fn setResolveInterceptor(self: *Vat, interceptor: ?ResolveInterceptor) void {
        self.resolve_interceptor = interceptor;
    }
};
