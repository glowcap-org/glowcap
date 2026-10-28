//! A vat: a turn loop over local actors and session Ports.
//!
//! This is glowcap's Goblins-shaped actor model, expressed in Zig. It is
//! where local actors meet the OCapN engine. A Vat owns local actors and queued
//! turns. One or more Ports own session-specific wire names and route remote
//! sends. You drive it
//! explicitly. It owns no I/O and no scheduler thread, so it stays in the same
//! sync, no-I/O core as the engine it rides on.
//!
//! An actor is any type with `pub fn handle(self: *@This(), turn: *Turn, msg:
//! Delivery) !model.Argument` (and, optionally, `pub fn deinit(self, allocator)`).
//! Its mutable `self` *is* its state: where Goblins returns a fresh behavior via
//! `bcom`, a Zig actor assigns its own fields. It is the same "become" idea,
//! expressed through Zig's ordinary mutable state. A mutable actor's turn is
//! not transactional: `self` mutations are not rolled back on a handler error,
//! the caller still sees the break, but writes made before the failure persist.
//! Use the persistent flavor for all-or-nothing turns. Its staged `become` is
//! discarded when the handler errors.
//!
//! Ownership at the handler boundary is *turn-scoped*. The `Delivery` a handler
//! receives borrows its arguments as views for the duration of the turn: a wire
//! deliver's views read the frame's bytes where they lie, and a local call's
//! views project the caller's owned arguments. For its reply a
//! handler has three choices, and the vat reclaims storage after each. It
//! can return a value owned by its own `self` or aliased from the message, which
//! allocates nothing. It can allocate the reply and any scratch from
//! `turn.arena`, the per-turn allocator the vat hands every handler. The vat owns
//! that arena and resets it when its next top-level turn begins, so a handler
//! never frees its own reply and never leaks one. Or a mutable handler can
//! *transfer* an owned byte field to the vat with `turn.moveOut`, an O(1)
//! hand-off where copying the buffer onto the arena would be O(len). The vat
//! then owns the bytes and frees them on the same schedule as the arena. In
//! every case the reply is valid until the vat's next top-level turn: within
//! that window the vat clones it for the local vow's listener or encodes it
//! onto the wire. To keep a value beyond
//! your turn, store it in `self` or copy it. Never return storage that ends
//! before the turn does. A `Resolution` delivered to a listener follows the
//! same rule. It is valid only for that listener call, so a listener that keeps
//! it copies first.
//!
//! An eventual-send's message is the mirror image: `send` and `tell` borrow
//! the verb and args only for the duration of the call. The local arm clones
//! them into an ingress-attributed queue chunk (a queued turn runs at the next
//! `drive`, after the turn arena the caller built them in has been reset), and
//! the far arm encodes them onto the wire inside `peer.sendBorrowed`. Either
//! way the caller's storage is free the moment the send returns.
//!
//! Two verbs, matching Goblins:
//!   * `Vat.near` is the synchronous near-call (`$`). It runs an actor's handler
//!     immediately and returns its value. It is legal only for a local ref in the
//!     same vat, exactly as Goblins forbids `$` to a far ref.
//!   * `Port.send` is eventual send (`<-`). A local ref queues a Vat turn. A far
//!     ref sends `op:deliver` over that Port. Either way it returns a `Vow`.
//!
//! A `Vow` is observed with `Vat.on` and has no matching `off`. A listener fires
//! exactly once, when the vow settles or when `breakFarVows` breaks every far vow
//! on disconnect, so there is nothing to cancel: dropping interest before a settle
//! is the break path's job, not a listener removal.
//!
//! The unified `Ref` can name a local actor or a far object, and a `Vow`
//! can settle from a local turn or from a wire answer. Location-transparent
//! sends enter through a session `Port`. Bare `Vat.send` is local-only. The
//! engine stays focused on codecs and authority. The vat sits above it and
//! imports the engine, never the reverse.
//!
//! ## Local time-travel (snapshot / restore)
//!
//! A vat can `snapshot` its local actor heap and later `restore` it, Goblins's
//! `snapshot-whactormap` shaped in Zig (ADR-0015). Each actor's state lives behind
//! a refcounted `StateBox`, so a snapshot shares state pointers rather than copying
//! bytes, O(objects), no per-byte clone, and the count is non-atomic because a
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
//!     copy-on-write, full Goblins parity.
//! An actor that is neither cloneable nor persistent makes `snapshot` fail with
//! `NotSnapshottable`, so a silent partial snapshot is impossible.
//!
//! Time-travel is **local only.** A snapshot captures local actor state and
//! it never touches `peer`, `exports`, far listeners, or the turn
//! arenas. A restore rewinds no remote peer, and far references in restored state
//! are copied as data, their wire meaning is engine-owned and forward-only. Both
//! `snapshot` and `restore` require quiescence (no turn or drive in flight, empty
//! queue), else `NotQuiescent`.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const reply_interceptor = @import("interceptor.zig");

const boxed = @import("boxed.zig");
const errors = @import("errors.zig");
const ingress_mod = @import("ingress.zig");
const frame = @import("frame.zig");
const port_mod = @import("port.zig");
const turn_mod = @import("turn.zig");
const turn_commit = @import("turn_commit.zig");
const vows_mod = @import("vows.zig");

/// The per-turn handler context (see `turn.Turn`).
pub const Turn = turn_mod.Turn;

// The vat's steady footprint bounds, one per reclaim site, mirroring the
// engine's `peer.queue.steady_retain_bytes` posture. A Vat retains one spare
// queue chunk globally, never one per ingress; its payload
// arena keeps at most the bound below so ordinary traffic stays allocation-free
// after warming while burst chunks reclaim incrementally. Recorded in
// .agents/rules/memory.md's footprint budget. File-level so the sibling vat
// modules and the footprint tests share them.
/// Turn-arena bound, applied at the outermost-turn reset in `frame.beginTurn`.
pub const steady_turn_arena_bytes = 4096;
/// Payload-arena bound for the Vat-wide spare queue chunk.
pub const steady_spare_arena_bytes = 4096;
/// Settle-arena bound, applied at the depth-0 reset in the far-resolve settle.
pub const steady_settle_arena_bytes = 4096;
/// Backing bound for plain ArrayLists such as `moved_replies`, and the target
/// size of one queue chunk's fixed row array.
pub const steady_list_bytes = 4096;
const Cell = boxed.Cell;
const StateBox = boxed.StateBox;
const releaseBox = boxed.releaseBox;

/// A captured local actor heap (see `boxed.Snapshot`).
pub const Snapshot = boxed.Snapshot;

/// A reference a `Port` can eventual-send to, wherever the object lives.
pub const Ref = union(enum) {
    /// An actor in this vat. `near` and `send` run its turns here.
    local: u64,
    /// A partner-hosted object the Port's peer holds as an import. `Port.send`
    /// routes to it as an `op:deliver`. `near` and bare `Vat.send` refuse it.
    far: model.FarRef,
};

/// A handle to the eventual result of a send, the vow of E/Goblins:
/// unsettled until the turn runs or the partner resolves, observed with
/// `Vat.on` for local vows or `Port.on` for far vows.
pub const Vow = union(enum) {
    /// Result of a local send. Settled by `Vat.drive`. A resolver vow
    /// (`Vat.spawnVow`, ADR-0014) shares this arm and namespace and is
    /// settled by `Vat.fulfillVow` / `Vat.breakVow` instead.
    local: u64,
    /// Result of a far send: the question the partner resolves, by identity.
    /// The session reuses a released answer position, so the vow carries the
    /// stamp of the row it names and a stale vow observes nothing.
    far: engine.OutboundAnswerTarget,
};

/// Which settlement namespace a freshly minted vow will occupy. Exposed so
/// adapters can reserve the matching one-shot listener slot before they commit
/// the send that creates the vow. The reservation makes listener installation
/// infallible after that semantic commit.
pub const VowLocation = std.meta.Tag(Vow);

/// Capacity for one future listener in exactly one settlement namespace.
/// Obtained from `Port.reserveListener` and consumed by `Port.onReserved`.
pub const ListenerReservation = struct {
    location: VowLocation,
};

/// A resolver pair (ADR-0014): the vow is the read side, the resolver id is
/// the settle authority, and neither confers the other. The resolver id lives
/// in the minting vat's namespace and dies with it.
pub const ResolverPair = struct {
    vow: Vow,
    resolver: u64,
};

/// Capacity for one resolver pair in both Vat indexes, and the ids the pair
/// will take. The pair does not exist until `spawnReservedVow` consumes this
/// reservation, so an adapter can reserve its own rows first and make the
/// cross-layer commit allocation-free.
pub const ResolverPairReservation = struct { vow: u64, resolver: u64 };

pub const Message = @import("behavior.zig").Message;
pub const Delivery = @import("behavior.zig").Delivery;
pub const OpaqueMessage = @import("behavior.zig").OpaqueMessage;

pub const IngressId = ingress_mod.IngressId;
pub const QueueLimits = ingress_mod.QueueLimits;
const QueueChunk = ingress_mod.QueueChunk;
const IngressState = ingress_mod.IngressState;
const PendingLocalVowKey = vows_mod.PendingLocalVowKey;

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

/// How a vow settled with no introduction: `Resolution` minus `give`. A
/// resolver settle, a queued turn's completion, and the settlement a host
/// tier feeds `Port.settleFar` all carry one, because the executor above the
/// vat redeems every give before the vat sees it, and only the wire resolve
/// arm of `Port.serve` widens it. The payload is borrowed for the listener
/// call, exactly as `Resolution`'s is.
pub const Outcome = union(enum) {
    fulfilled: model.Argument,
    broken: []const u8,

    pub fn resolution(self: Outcome) Resolution {
        return switch (self) {
            .fulfilled => |value| .{ .fulfilled = value },
            .broken => |reason| .{ .broken = reason },
        };
    }
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
    /// The recipient session key the give is addressed to. The withdraw must
    /// sign with its secret half.
    recipient_key: []const u8,
};

pub const InterceptOutcome = reply_interceptor.Outcome;
pub const ResolveInterceptor = reply_interceptor.Interceptor;

/// A one-shot vow listener: `func(ctx, resolution)` fires when the vow
/// settles. `ctx` is the caller's opaque state (or null).
pub const Listener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, resolution: Resolution) void,
};

pub const HostedActor = @import("behavior.zig").HostedActor;

pub const Error = errors.Error;
pub const IngressCancellationError = errors.IngressCancellationError;

/// The id `ids` spends next, refused once its space is spent.
pub fn peekId(ids: foundation.id_issuer.IdIssuer) Error!u64 {
    return ids.peek() orelse error.ResourceExhausted;
}

/// One CapTP session's projection of this Vat.
pub const Port = port_mod.Port;

/// One layer's stake in an outermost turn (ADR-0058). `commit` runs in
/// enrollment order and `abort` in reverse, so a later layer undoes its effect
/// before an earlier one releases what that effect used. status-allow: event or source ordering
/// Abort restores state without notifying observers. Optional `abort_notify`
/// runs after every participant has aborted, when listeners may reenter.
pub const TurnParticipant = struct {
    ctx: *anyopaque,
    commit: *const fn (ctx: *anyopaque, vat: *Vat) void,
    abort: *const fn (ctx: *anyopaque, vat: *Vat, reason: []const u8) void,
    abort_notify: ?*const fn (ctx: *anyopaque, vat: *Vat, reason: []const u8) void = null,
};

pub const TurnBreak = struct { port: *Port, answer: engine.OutboundAnswerTarget };

/// One single-threaded container of local objects, the Goblins-shaped layer
/// above the engine. Spawn objects, near-call them with `near` (`$`),
/// eventual-send to local objects with `send` (`<-`), and `drive` queued turns
/// to completion. Attach Ports for session-scoped far sends. Sync and no-I/O
/// by contract (ADR-0014). Everything spawned or queued lives on the vat's
/// allocator and arenas, freed in `deinit`.
pub const Vat = struct {
    allocator: std.mem.Allocator,
    /// Destructors may release capabilities to sibling actors. Once teardown
    /// owns every actor, those root updates are redundant and the actor table
    /// may already be draining. Make them terminal no-ops instead of mutating
    /// the table under its own deinitialization walk.
    tearing_down: bool = false,
    actors: std.AutoHashMapUnmanaged(u64, Cell) = .{},
    queue_limits: QueueLimits = .{},
    /// A trusted adapter copy cannot drive or change queue admission while
    /// its preflight owns unpublished capacity.
    queue_copy_active: bool = false,
    local_ingress: IngressState = .{ .id = .local },
    /// Non-local ingress rows are heap-pinned so the intrusive runnable ring
    /// stays pointer-stable while the table grows inside a running turn.
    ingresses: foundation.handle_table.Owner(IngressId, *IngressState) = .empty,
    runnable_head: ?*IngressState = null,
    runnable_tail: ?*IngressState = null,
    /// One Vat-wide spare amortizes ordinary local enqueue without retaining a
    /// chunk per idle ingress. Every additional completed chunk is freed.
    spare_chunk: ?*QueueChunk = null,
    listeners: std.AutoHashMapUnmanaged(u64, Listener) = .{},
    /// One installed callback identity for Vat-owned forwarding contexts.
    /// Zig archives compile distinct function addresses. Retaining this
    /// address costs one word per Vat, avoiding a tag on every listener and
    /// allowing exact teardown and iterative settlement across code images.
    forward_listener: @FieldType(Listener, "func"),
    /// Local vows whose turns are still pending. Fair ingress rotation can
    /// settle vow ids out of global numeric order, so a FIFO high-water
    /// mark is unsound. This index makes late-listener refusal independent of
    /// scheduling order.
    pending_local_vows: std.AutoHashMapUnmanaged(PendingLocalVowKey, void) = .{},
    /// Resolver id → the local vow it settles (ADR-0014). A row is consumed
    /// by the first settle attempt, so the map holds exactly the live settle
    /// authorities. Freed with the vat. Ids start at 1 so 0 stays unminted
    /// for adapter tiers that want a null sentinel.
    resolver_vows: std.AutoHashMapUnmanaged(u64, u64) = .{},
    resolver_ids: foundation.id_issuer.IdIssuer = .{},
    // The turn and settle arenas below, plus the Vat-wide spare chunk's payload
    // arena, retain backing storage across a reset. A safety build does not
    // poison that retained region.
    // The use-after-reset class is closed at the root instead: each value that
    // must outlive a reset is cloned clear of it (see `settleLocal` and the
    // become-in-turn reply), and the scribble tests overwrite the arena to catch
    // a stale borrow. A blanket poison-on-reset detector is not added because
    // `std.heap.ArenaAllocator` retains its buffer with no poison hook and a
    // private node type, so a correct one would need fragile internals or a
    // bespoke arena, both disproportionate to a debug-only aid.
    /// Per-turn scratch the vat hands each handler as `turn.arena`. A handler's
    /// reply and scratch live here. The vat reclaims the whole arena when its next
    /// outermost turn begins (when `turn_depth` returns to 0 and rises again), so a
    /// reply stays valid until then and no handler frees or leaks its own reply.
    turn_arena: std.heap.ArenaAllocator,
    /// Nesting depth of in-flight turns. The turn arena resets only at depth 0, so a
    /// near-call or send made inside a turn shares that turn's scratch rather than
    /// pulling it out from under the call in flight.
    turn_depth: u32 = 0,
    /// Nesting depth of in-flight `drive` calls. A listener may open a nested
    /// drive. The runnable ring is Vat-owned so nested drives continue from the
    /// fair rotation point rather than re-running the active turn.
    drive_depth: u32 = 0,
    /// The running outermost turn's staged local sends, per ingress (ADR-0058).
    staged: std.ArrayListUnmanaged(ingress_mod.StagedIngress) = .empty,
    /// Set when the outermost turn fails, so its close drops the held sends.
    turn_failure: ?[]const u8 = null,
    /// Layers that recorded an effect in the running outermost turn and wait
    /// for its outcome (ADR-0058), in enrollment order.
    participants: std.ArrayListUnmanaged(TurnParticipant) = .empty,
    /// Answer slots reserved by far sends before their effect. Listeners stay
    /// at their Port until notification, so cancellation keeps its usual owner.
    turn_breaks: std.ArrayListUnmanaged(TurnBreak) = .empty,
    turn_break_reservations: usize = 0,
    /// Scratch for local and far fulfilled-listener calls. Queue chunks may
    /// reclaim independently, so settlement has one depth-guarded arena that a
    /// listener-opened drive cannot reset under the borrowed value.
    settle_arena: std.heap.ArenaAllocator,
    /// Nesting depth of in-flight far-resolve settles. A far listener can
    /// re-enter `serve` (a driver pump: `driver.Session.step` then `drainEvents`),
    /// and the nested settle must not reset the arena the outer listener's
    /// value still lives in. Only the return to depth 0 resets it.
    settle_depth: u32 = 0,
    actor_ids: foundation.id_issuer.IdIssuer = .{},
    vow_ids: foundation.id_issuer.IdIssuer = .{},
    /// Reply bytes handlers moved to the vat via `Turn.moveOut`, awaiting free.
    /// They share the turn arena's lifetime: the vat frees them when its next
    /// outermost turn begins, so a moved reply stays valid for the caller until
    /// then, with no copy, since the handler already owned the bytes.
    moved_replies: std.ArrayList([]const u8) = .empty,
    /// State boxes a `become` has swapped out of their actor, awaiting their
    /// last reference to drop. Held to the same boundary as `moved_replies`,
    /// and for the same reason: a handler may return a reply that borrows the
    /// state it ran as, and that reply stays valid until the vat's next
    /// outermost turn. The frame that installs a become can sever its own
    /// reply, but not one an *earlier* frame of the same actor already handed status-allow: event or source ordering
    /// back to a caller still running. That frame has closed. Freeing the box
    /// here instead of at the install makes both replies outlive it.
    /// Capacity also escrows one unused slot per live actor. That makes
    /// last-root release and destructor/frame unwind allocation-free: the row
    /// leaves `actors` before its box consumes the corresponding slot.
    retired_boxes: std.ArrayList(*boxed.StateBox) = .empty,

    pub const Options = struct {
        queue_limits: QueueLimits = .{},
    };

    /// A pure-local vat (no wire). `near`/`send`/`drive` over local actors only.
    pub fn init(allocator: std.mem.Allocator) Vat {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: Options) Vat {
        return .{
            .allocator = allocator,
            .forward_listener = @import("forwarding.zig").forwardListener,
            .queue_limits = options.queue_limits,
            .turn_arena = std.heap.ArenaAllocator.init(allocator),
            .settle_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Vat) void {
        std.debug.assert(!self.queue_copy_active);
        self.tearing_down = true;
        var it = self.actors.valueIterator();
        while (it.next()) |cell| {
            // A become promoted by the last frame but never installed (a vat torn
            // down mid-run) still owns its box.
            if (cell.pending_become) |box| releaseBox(self.allocator, box);
            releaseBox(self.allocator, cell.box);
        }
        self.actors.deinit(self.allocator);
        turn_commit.discard(self);
        self.participants.deinit(self.allocator);
        self.turn_breaks.deinit(self.allocator);
        ingress_mod.freeIngressQueue(self, &self.local_ingress);
        var ingress_it = self.ingresses.valueIterator();
        while (ingress_it.next()) |state_ptr| {
            ingress_mod.freeIngressQueue(self, state_ptr.*);
            self.allocator.destroy(state_ptr.*);
        }
        self.ingresses.deinit(self.allocator);
        if (self.spare_chunk) |chunk| {
            chunk.arena.deinit();
            self.allocator.destroy(chunk);
        }
        // Reclaim only the listener contexts the vat itself allocated, keyed by
        // function-pointer identity: a local `forward` heap-allocates a
        // `ForwardContext` whose only free path is the listener firing, which a
        // never-drained queue at teardown skips. Every other listener context is
        // caller-owned (an `on` caller's stack state), so it must be left alone.
        vows_mod.freeOwnedForwardContexts(self, &self.listeners);
        self.listeners.deinit(self.allocator);
        self.pending_local_vows.deinit(self.allocator);
        self.resolver_vows.deinit(self.allocator);
        frame.drainMovedReplies(self);
        self.moved_replies.deinit(self.allocator);
        frame.releaseRetiredBoxes(self);
        self.retired_boxes.deinit(self.allocator);
        self.turn_arena.deinit();
        self.settle_arena.deinit();
    }

    /// Adopt initial state on every outcome, reclaiming it on refusal.
    pub fn spawn(self: *Vat, comptime Behavior: type, initial: Behavior) Error!Ref {
        return self.registerBox(try boxed.makeBox(self, Behavior, initial));
    }

    pub const discardInitial = boxed.discardInitial;

    /// Enroll a freshly minted `box` as the next actor and return its local ref.
    /// The one registration tail `spawn` and `spawnHosted` share. It adopts the
    /// box (releasing it if the table insert fails, so the caller never frees a
    /// box it handed over).
    fn registerBox(self: *Vat, box: *StateBox) Error!Ref {
        errdefer releaseBox(self.allocator, box);
        try self.admitMutation();
        const id = try peekId(self.actor_ids);
        // Actor registration is the fallible seam that escrows its eventual
        // retirement. Preserve room for every become an open frame may already
        // have staged as well; registration must not spend their reservations.
        try frame.reserveRetirementCapacity(self, 1, self.turn_depth);
        try self.actors.put(self.allocator, id, .{ .box = box });
        self.actor_ids.commit(id);
        return .{ .local = id };
    }

    /// Spawn a *hosted* actor (ADR-0022): its state and behavior live outside
    /// the vat, behind `hosted.ctx`, reached through the callbacks in
    /// `HostedActor`. This is the C-ABI hosting path a non-Zig consumer uses.
    /// The actor is otherwise ordinary. It is delivered to, driven, sent to,
    /// and listened on exactly like a Zig one, and its `handle` gets the full
    /// `Turn`. Like `spawn`, mints no export (bind it with `Port.bindExport` to
    /// reach it). `hosted.free`, if set, runs on every outcome, including a failed
    /// spawn, which frees `ctx` before returning the error, so the caller never
    /// double-frees. The box carries no `clone`, so a vat holding a hosted actor
    /// is not snapshottable (`snapshot` returns `NotSnapshottable`).
    pub fn spawnHosted(self: *Vat, hosted: HostedActor) Error!Ref {
        return self.registerBox(try boxed.makeHostedBox(self, hosted));
    }

    /// Roll back a freshly spawned actor that failed before any export binding
    /// or application reference became observable. The caller must hold the
    /// exact `Ref` returned by `spawn`/`spawnHosted` and call this only on that
    /// operation's unwind. Actor ids remain monotonic and are not reused.
    pub fn discardFreshActor(self: *Vat, actor: Ref) void {
        const id = switch (actor) {
            .local => |local| local,
            .far => unreachable,
        };
        const removed = self.actors.fetchRemove(id) orelse unreachable;
        std.debug.assert(removed.value.pending_become == null);
        releaseBox(self.allocator, removed.value.box);
    }

    /// The state of live actor `id` when it runs `Behavior`, else null. A
    /// read-only peek for an owner that must recognize its own actor kind.
    pub fn stateAs(self: *const Vat, comptime Behavior: type, id: u64) ?*const Behavior {
        const cell = self.actors.getPtr(id) orelse return null;
        return boxed.stateAs(Behavior, cell.box);
    }

    pub fn hasActor(self: *const Vat, id: u64) bool {
        return self.actors.contains(id);
    }

    /// Enroll `participant` in the running outermost turn, once per `ctx`. It
    /// receives `commit` inside the frame before the reply leaves, or `abort`
    /// after the frame closes, exactly once. Observer callbacks belong in
    /// `abort_notify`, after all cleanup. Enrollment is fallible, so a layer
    /// enrolls before it records the effect it will undo.
    pub fn enrollTurn(self: *Vat, participant: TurnParticipant) !void {
        std.debug.assert(self.turn_depth != 0);
        for (self.participants.items) |existing| if (existing.ctx == participant.ctx) return;
        try self.participants.append(self.allocator, participant);
    }

    /// Refuse execution and publication while an adapter copy owns unpublished
    /// admission, or after teardown has begun. Custody release remains legal.
    pub fn admitMutation(self: *const Vat) error{ ReenteredAdmission, VatReleased }!void {
        if (self.tearing_down) return error.VatReleased;
        if (self.queue_copy_active) return error.ReenteredAdmission;
    }

    /// A turn or queue drive owns execution, including retired-state cleanup.
    /// Adapters may enqueue effects here, but defer an independent drive until
    /// the outer boundary returns.
    pub fn isExecuting(self: *const Vat) bool {
        return self.queue_copy_active or self.turn_depth != 0 or self.drive_depth != 0;
    }

    pub const hasRetiredState = frame.hasRetiredState;

    /// Add one explicit root to a live actor row (ADR-0014). Tolerant of an
    /// absent row: a rooting relationship can outlive a row `restore` removed,
    /// and its bookkeeping then fails closed instead of crashing.
    pub fn retainActor(self: *Vat, id: u64) void {
        if (self.tearing_down) return;
        if (self.actors.getPtr(id)) |cell| cell.roots += 1;
    }

    /// Release one explicit root (ADR-0014). The last root retires the row,
    /// immediately when the actor is idle, or at its running frame's unwind,
    /// and parks the box until the next outermost-turn boundary, the borrowed
    /// reply's lifetime. Tolerant of an absent row, like `retainActor`.
    pub fn releaseActor(self: *Vat, id: u64) void {
        if (self.tearing_down) return;
        const cell = self.actors.getPtr(id) orelse return;
        std.debug.assert(cell.roots > 0);
        cell.roots -= 1;
        if (cell.roots == 0 and cell.running == 0) frame.retireActorRow(self, id);
    }

    /// The synchronous near-call (`$`): run `target`'s handler now and return its
    /// value. Legal only for a local ref. A far ref must be reached with
    /// `Port.send`.
    /// The returned `Argument` is borrowed from the actor's state or the message
    /// (see the module header) and is valid only as long as both are. A caller
    /// that keeps it copies first.
    pub fn near(self: *Vat, target: Ref, msg: Message) anyerror!model.Argument {
        return self.nearFromIngress(.local, target, msg);
    }

    /// `near` on one causal ingress.
    pub fn nearFromIngress(self: *Vat, ingress: IngressId, target: Ref, msg: Message) anyerror!model.Argument {
        return self.nearDelivery(.{ .ingress = ingress }, target, msg.delivery());
    }

    /// `near` with a session Port's authority, on that Port's ingress.
    pub fn nearFromPort(self: *Vat, port: *Port, target: Ref, msg: Message) anyerror!model.Argument {
        return self.nearDelivery(.{ .port = port }, target, msg.delivery());
    }

    /// The near call a forwarding handler makes with the delivery it holds:
    /// the target reads the same views, and nothing is copied on the hop.
    pub fn nearDelivery(self: *Vat, source: Turn.Source, target: Ref, msg: Delivery) anyerror!model.Argument {
        try self.admitMutation();
        const state = try ingress_mod.ingressState(self, source.ingressId());
        state.active_turns += 1;
        defer state.active_turns -= 1;
        return switch (target) {
            .local => |id| frame.callLocal(self, source, id, msg),
            .far => Error.NotNearCallable,
        };
    }

    pub const openIngress = ingress_mod.openIngress;
    pub const hasIngress = ingress_mod.hasIngress;
    pub const closeIngress = ingress_mod.closeIngress;
    pub const discardFreshIngress = ingress_mod.discardFreshIngress;
    pub const cancelIngress = ingress_mod.cancelIngress;
    pub const cancelLocalIngress = ingress_mod.cancelLocalIngress;
    pub const send = ingress_mod.send;
    pub const sendOpaqueFromIngress = ingress_mod.sendOpaqueFromIngress;
    pub const tellOpaqueFromIngress = ingress_mod.tellOpaqueFromIngress;
    pub const sendFromIngress = ingress_mod.sendFromIngress;
    pub const sendObservedFromIngress = ingress_mod.sendObservedFromIngress;
    pub const tell = ingress_mod.tell;
    pub const tellFromIngress = ingress_mod.tellFromIngress;
    pub const drive = ingress_mod.drive;
    pub const driveBudgeted = ingress_mod.driveBudgeted;
    pub const driveIngressBudgeted = ingress_mod.driveIngressBudgeted;

    pub const spawnVow = vows_mod.spawnVow;
    pub const reserveResolverPair = vows_mod.reserveResolverPair;
    pub const spawnReservedVow = vows_mod.spawnReservedVow;
    pub const fulfillVow = vows_mod.fulfillVow;
    pub const breakVow = vows_mod.breakVow;
    pub const breakVowTerminal = vows_mod.breakVowTerminal;
    pub const on = vows_mod.on;
    pub const takeListener = vows_mod.takeListener;

    pub const snapshot = boxed.snapshot;
    /// Rewind the local actor heap to a snapshot (see `boxed.restore`).
    pub const restore = boxed.restore;

    pub const DriveProgress = ingress_mod.DriveProgress;
};
