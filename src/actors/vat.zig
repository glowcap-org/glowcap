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
/// (`handle`/`drop`/`clone`) so a snapshot can rebuild a working cell from a
/// shared box alone. The box is the header of a single `Boxed` heap block that
/// also carries the state (`ptr` points at that trailing field), so an actor's
/// lifetime is one allocation and one free, never a box/state pair.
const StateBox = struct {
    ptr: *anyopaque,
    /// Live references: the vat's own cell plus one per snapshot that shares it.
    refs: usize,
    handle: *const fn (state: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument,
    /// Free the whole `Boxed` block this box heads, running the state's
    /// `deinit` first. The box and its state are one allocation, so there is
    /// no separate state free.
    drop: *const fn (box: *StateBox, allocator: std.mem.Allocator) void,
    /// Deep-copy this box's state into a fresh `Boxed` block, for copy-on-write.
    /// Null when the actor opted out of cloning; such a box is snapshottable only
    /// if it is `persistent`.
    clone: ?*const fn (box: *const StateBox, allocator: std.mem.Allocator) std.mem.Allocator.Error!*StateBox,
    /// Set at spawn for a persistent actor: its state is never mutated in place,
    /// so copy-on-write is skipped and a snapshot shares it directly.
    persistent: bool,
};

/// The one heap block behind an actor: the refcounted `StateBox` header and the
/// behavior's state, side by side. A spawn, a `become`, and a copy-on-write
/// clone each cost exactly one allocation, and `releaseBox` frees exactly one
/// block through the box's `drop`.
fn Boxed(comptime Behavior: type) type {
    return struct {
        box: StateBox,
        state: Behavior,
    };
}

/// The heap block behind a *hosted* actor (ADR-0071): the refcounted `StateBox`
/// header beside the `HostedActor` the vat calls through. `box.ptr` points at
/// the block, so the box-level `handle` recovers the callback and `ctx` from it.
/// The box carries no `clone`, so such an actor is not snapshottable — the vat
/// cannot copy state it does not own — and copy-on-write already no-ops on a
/// null clone. One allocation, one free through `drop`, like `Boxed`.
const HostedBlock = struct {
    box: StateBox,
    actor: HostedActor,

    fn handle(state: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument {
        const self: *HostedBlock = @ptrCast(@alignCast(state));
        return self.actor.handle(self.actor.ctx, turn, msg);
    }

    fn drop(box: *StateBox, allocator: std.mem.Allocator) void {
        const self: *HostedBlock = @fieldParentPtr("box", box);
        if (self.actor.free) |f| f(self.actor.ctx);
        allocator.destroy(self);
    }
};

/// One actor slot in the vat's heap: a single owning reference to a `StateBox`,
/// plus the bookkeeping that keeps a `become` safe under reentrant near-calls.
const Cell = struct {
    box: *StateBox,
    /// Frames currently executing this actor. Near-calls can re-enter the same
    /// actor (a handler near-calls itself, directly or through a cycle), so this
    /// nests. A staged `become` installs only when it returns to zero, so the
    /// box an outer frame still holds as `self` is never freed under it.
    running: u32 = 0,
    /// The next state box, promoted here by a frame that returned successfully
    /// and installed when `running` reaches zero. Last write wins across the
    /// frames of one reentrant run, matching Goblins's last-`bcom`-wins.
    pending_become: ?*StateBox = null,
};

/// A staged `Turn.become`: the next state box, held on the turn until the frame
/// returns. On success it is promoted onto the actor's `Cell`; on a handler
/// error it is discarded, so a failed turn leaves the actor unchanged.
const PendingBecome = struct { id: u64, box: *StateBox };

/// Release one reference to `box`, freeing its whole `Boxed` block (state
/// `deinit` included) when the last reference drops. The single chokepoint for
/// box lifetime, shared by the vat and by `Snapshot.deinit` so both count the
/// same way.
fn releaseBox(allocator: std.mem.Allocator, box: *StateBox) void {
    box.refs -= 1;
    if (box.refs == 0) box.drop(box, allocator);
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
    /// Where this turn came from — the one axis `forward` dispatches on. No
    /// default: every constructor states the provenance, and the old illegal
    /// combination (a near-call carrying a wire answer) is unrepresentable.
    origin: union(enum) {
        /// A local, value-bearing frame: a synchronous near-call (`$`) or a
        /// queued eventual-send turn. The handler's return value is consumed
        /// directly — the near-caller's reply, or the vow's resolution — so
        /// `forward` forwards synchronously and returns the target's value.
        local,
        /// An inbound wire deliver, carrying the answer this turn must settle,
        /// or null for a no-answer deliver (a wire `tell`). `forward` defers
        /// the answer onto the forwarded send's vow.
        served: ?model.AnswerPosition,
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
        return self.vat.near(target, msg);
    }
    /// Eventual-send to a local or far reference, returning the reply
    /// `Vow` — the `<-` of this layer (see `Vat.send`).
    pub fn send(self: *Turn, target: Ref, msg: Message) Error!Vow {
        return self.vat.send(target, msg);
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
        return self.vat.stageBecome(self, Behavior, next);
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
    /// Eventual-path accounting, honestly: on a listened `send` → `drive`
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
    /// behavior that returns `(apply <- target args)`; pancake's handler returns
    /// a concrete value, so `forward` instead defers the inbound answer and
    /// settles it when the forwarded send settles, local or far. `target` may be
    /// local or far: a far forward is what lets a holder hand out an attenuated
    /// or revocable view of a capability it imported over the wire.
    ///
    /// What comes back depends on the turn's `origin`: a `.local` frame gets
    /// the target's real value (the vat consumes the return directly, so the
    /// forward runs as a synchronous near-call); a `.served` turn gets a `void`
    /// placeholder the vat ignores, with the real answer riding the forwarded
    /// vow — or, for a no-answer wire `tell`, a fire-and-forget forward.
    /// Forwarding does not preserve promise pipelining *through* the proxy: a
    /// partner pipelining on the proxy's answer queues on this side until the
    /// forwarded send settles (ADR-0064).
    pub fn forward(self: *Turn, target: Ref, msg: Message) anyerror!model.Argument {
        return self.vat.forwardTurn(self, target, msg);
    }

    /// Break this turn's own answer with `message` — the served-turn spelling
    /// of a handler failure that must carry its diagnostic. A native handler
    /// breaks by returning an error, whose `@errorName` becomes the reason; a
    /// hosted behavior's return code carries no message at all, so this verb
    /// is how a caretaker's "Revoked" or an attenuator's "Attenuated" crosses
    /// the boundary intact. The answer resolves broken now (a no-answer wire
    /// `tell` breaks nothing) and the turn is marked forwarded so the handler's
    /// eventual return value resolves nothing — the handler still returns
    /// normally after calling this. A second call in the same turn is a no-op:
    /// the answer already settled. Legal only on a served turn; a `.local`
    /// frame's caller consumes the return value directly, so a break has
    /// nowhere to land and the handler raises instead (`NotLocal`).
    pub fn breakWith(self: *Turn, message: []const u8) !void {
        switch (self.origin) {
            .served => |answer| {
                if (self.forwarded) return;
                try self.vat.resolveBreak(answer, message);
                self.forwarded = true;
            },
            .local => return Error.NotLocal,
        }
    }
};

/// Heap context a forwarded turn's vow listener carries: the vat to resolve
/// against and the deferred inbound answer. Freed by the listener once it fires
/// (on settle, or on a disconnect break via `breakFarVows`).
const ForwardContext = struct { vat: *Vat, answer: model.AnswerPosition };

fn forwardListener(ctx: ?*anyopaque, resolution: Resolution) void {
    const fc: *ForwardContext = @ptrCast(@alignCast(ctx.?));
    defer fc.vat.allocator.destroy(fc);
    // Best-effort: a failed resolve strands the partner's answer until teardown
    // (the same class as a refused GC release), never a fault on this side.
    switch (resolution) {
        .fulfilled => |value| fc.vat.resolveFulfill(fc.answer, value) catch {},
        .broken => |message| fc.vat.resolveBreak(fc.answer, message) catch {},
        // A give is addressed to THIS vat's session key; a forwarded copy
        // could never be redeemed by the partner, so the honest relay is a
        // break naming why.
        .give => fc.vat.resolveBreak(fc.answer, "introduction not forwardable") catch {},
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
    /// re-enter `serve` (a driver pump: `BlockingSession.step` → `drainEvents`),
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

    // The vat's steady footprint bounds, one per reclaim site, mirroring the
    // engine's `steady_queue_bytes` posture (src/ocapn/engine/mod.zig): at
    // one-vat-per-connection scale, capacity a burst grew must not stay
    // pinned for the connection's life — capacity at or under the bound is
    // retained so steady turns stay allocation-free, capacity above it is
    // freed at the same drain boundary that used to retain it. The named
    // trade is one growth re-allocation at the start of the *next* burst
    // episode, never per turn — the same trade the engine documents, and why
    // `retain_with_limit` beats `free_all`. Recorded in
    // .agents/rules/memory.md's per-session footprint budget.
    /// Turn-arena bound, applied at the outermost-turn reset in `beginTurn`.
    const steady_turn_arena_bytes = 4096;
    /// Queue-arena bound, applied at the outermost drive's full-drain reset.
    const steady_queue_arena_bytes = 4096;
    /// Settle-arena bound, applied at the depth-0 reset in `serve`'s
    /// far-resolve arm.
    const steady_settle_arena_bytes = 4096;
    /// Backing bound for the plain ArrayLists (`queue`, `moved_replies`):
    /// above it the drain point does `clearAndFree` instead of retaining,
    /// the engine `Queue.pop` idiom.
    const steady_list_bytes = 4096;
    /// Cap on `served_dropped_far`: the count of resolve-before-`on` drops the
    /// vat remembers to refuse a late `on`. Empty in the normal flow; the cap
    /// bounds a pathological stream of unclaimed drops (past it a late `on`
    /// parks, as before the guard).
    const max_served_dropped_far_answers = 256;

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
        self.drainMovedReplies();
        self.moved_replies.deinit(self.allocator);
        self.turn_arena.deinit();
        self.queue_arena.deinit();
        self.settle_arena.deinit();
    }

    /// Free every reply a handler moved to the vat and not yet reclaimed. Called
    /// when an outermost turn begins (mirroring the turn arena's reset) and at
    /// teardown, so a moved reply lives exactly as long as a borrowed one would.
    fn drainMovedReplies(self: *Vat) void {
        for (self.moved_replies.items) |bytes| self.allocator.free(bytes);
        self.moved_replies.clearRetainingCapacity();
        if (self.moved_replies.capacity * @sizeOf([]const u8) > steady_list_bytes) {
            self.moved_replies.clearAndFree(self.allocator);
        }
    }

    /// Free the vat-owned `ForwardContext` behind every `forwardListener` entry
    /// in `map`, identified by function-pointer identity so caller-owned listener
    /// contexts are never touched. A fired listener removes its entry, so only
    /// unfired forwards remain here, making a double-free impossible.
    fn freeOwnedForwardContexts(self: *Vat, map: anytype) void {
        var it = map.valueIterator();
        while (it.next()) |listener| {
            if (listener.func == forwardListener) {
                const fc: *ForwardContext = @ptrCast(@alignCast(listener.ctx.?));
                self.allocator.destroy(fc);
            }
        }
    }

    /// Allocate a fresh `Boxed` block (`refs = 1`) owning a heap copy of
    /// `initial`, wiring the behavior's `handle`/`drop`/`clone` and persistent
    /// flavor. The one place a box is born from a value, shared by `spawn` and
    /// `become`; the copy-on-write path births its box through the wired
    /// `clone`. One allocation total — the merged header + state block. On
    /// failure it owns nothing: `initial`'s resources are reclaimed before the
    /// error returns.
    fn makeBox(self: *Vat, comptime Behavior: type, initial: Behavior) Error!*StateBox {
        const Block = Boxed(Behavior);
        const Glue = struct {
            fn handle(erased: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument {
                // A persistent actor never mutates `self` (that is why a snapshot
                // may share its state with no copy-on-write), so it is dispatched
                // through a `*const` receiver: the ordinary `self.field = x` then
                // fails to compile instead of silently writing through the pointer
                // a live snapshot shares. This enforces shallow immutability only;
                // a persistent actor still must not mutate through an interior
                // pointer it owns, which `*const self` cannot reach.
                if (comptime behaviorIsPersistent(Behavior)) {
                    const behavior: *const Behavior = @ptrCast(@alignCast(erased));
                    return behavior.handle(turn, msg);
                }
                const behavior: *Behavior = @ptrCast(@alignCast(erased));
                return behavior.handle(turn, msg);
            }
            fn drop(box: *StateBox, allocator: std.mem.Allocator) void {
                const block: *Block = @fieldParentPtr("box", box);
                if (@hasDecl(Behavior, "deinit")) block.state.deinit(allocator);
                allocator.destroy(block);
            }
            fn clone(box: *const StateBox, allocator: std.mem.Allocator) std.mem.Allocator.Error!*StateBox {
                // Reached only when `clone` was wired below, i.e. the actor
                // defines it; the guard keeps the body compilable for actors
                // that do not.
                if (@hasDecl(Behavior, "clone")) {
                    const behavior: *const Behavior = @ptrCast(@alignCast(box.ptr));
                    const fresh = try allocator.create(Block);
                    errdefer allocator.destroy(fresh);
                    // The by-value clone contract: the state's `clone` builds
                    // the next value, and the vat moves it into the fresh
                    // block, so the clone path is also one allocation.
                    fresh.state = try behavior.clone(allocator);
                    fresh.box = .{
                        .ptr = @ptrCast(&fresh.state),
                        .refs = 1,
                        .handle = box.handle,
                        .drop = box.drop,
                        .clone = box.clone,
                        .persistent = box.persistent,
                    };
                    return &fresh.box;
                }
                unreachable;
            }
        };

        const block = self.allocator.create(Block) catch |e| {
            // `initial` was never moved into heap state, but the contract still
            // promises its resources are reclaimed. `initial` is a by-value
            // parameter, so take a mutable local to reach its `deinit`.
            var orphan = initial;
            if (@hasDecl(Behavior, "deinit")) orphan.deinit(self.allocator);
            return e;
        };
        block.state = initial;
        block.box = .{
            .ptr = @ptrCast(&block.state),
            .refs = 1,
            .handle = Glue.handle,
            .drop = Glue.drop,
            .clone = if (@hasDecl(Behavior, "clone")) Glue.clone else null,
            .persistent = behaviorIsPersistent(Behavior),
        };
        return &block.box;
    }

    /// Spawn a local actor with `initial` state, returning a local `Ref`. No
    /// export position is minted: the actor has no wire position at all until
    /// it is bound with `bindExport` (or spawned through the driver's
    /// exporting `spawn`), and even a bound position stays unaddressable
    /// until its reference first marshals onto the wire. `initial` is
    /// consumed on every outcome: on failure its resources are reclaimed
    /// through the state's `deinit`, so the caller never frees it.
    pub fn spawn(self: *Vat, comptime Behavior: type, initial: Behavior) Error!Ref {
        const box = try self.makeBox(Behavior, initial);
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
        const box = try self.makeHostedBox(hosted);
        errdefer releaseBox(self.allocator, box);

        const id = self.next_actor;
        try self.actors.put(self.allocator, id, .{ .box = box });
        self.next_actor += 1;
        return .{ .local = id };
    }

    fn makeHostedBox(self: *Vat, hosted: HostedActor) Error!*StateBox {
        const block = self.allocator.create(HostedBlock) catch |e| {
            // The box was never built, but the contract promises `ctx` is
            // reclaimed on failure, mirroring how `spawn` reclaims a native
            // `initial` through its `deinit`.
            if (hosted.free) |f| f(hosted.ctx);
            return e;
        };
        block.actor = hosted;
        block.box = .{
            .ptr = @ptrCast(block),
            .refs = 1,
            .handle = HostedBlock.handle,
            .drop = HostedBlock.drop,
            .clone = null,
            .persistent = false,
        };
        return &block.box;
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
        if (self.turn_depth == 0) {
            _ = self.turn_arena.reset(.{ .retain_with_limit = steady_turn_arena_bytes });
            // Moved replies share the arena's lifetime, so reclaim the previous
            // outermost turn's moved bytes at the same boundary its scratch
            // resets. A borrowed reply from the last turn is now invalid too.
            self.drainMovedReplies();
        }
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
        // A shared, non-persistent box can only exist because `snapshot`
        // admitted it, and `snapshot` refuses a clone-less mutable box
        // (`NotSnapshottable`) — so `clone` is non-null here by invariant.
        // Failing loud is load-bearing: returning instead would silently
        // mutate state a live snapshot shares.
        const clone_fn = box.clone orelse unreachable;
        // The wired `clone` builds the whole fresh `Boxed` block (state cloned
        // by value into it), so the copy costs one block allocation.
        const new_box = try clone_fn(box, self.allocator);
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
        cell.running += 1;
        const arena = self.beginTurn();
        defer self.endTurn();
        // Install any promoted `become` only when this actor's outermost frame
        // unwinds, so a reentrant inner become never frees the box the outer
        // frame is still running as `self`.
        defer self.finishCellRun(id);
        var turn = Turn{ .vat = self, .self_ref = .{ .local = id }, .arena = arena, .origin = .local };
        if (box.handle(box.ptr, &turn, msg)) |value| {
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
            if (install_at_unwind and !self.replyOutlivesBox(value, turn.moves_begin)) {
                const severed = model.cloneArgument(arena, value) catch |err| {
                    if (turn.pending_become) |pending| releaseBox(self.allocator, pending.box);
                    return err;
                };
                if (turn.pending_become) |pending| self.promoteBecome(pending);
                return severed;
            }
            if (turn.pending_become) |pending| self.promoteBecome(pending);
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

    /// Promote a successful frame's staged become onto the actor's `Cell`, to be
    /// installed when the actor's outermost running frame unwinds. Last write
    /// wins across the frames of one reentrant run: an earlier promoted box that
    /// never installed is released here.
    fn promoteBecome(self: *Vat, pending: PendingBecome) void {
        // A running actor is never removed — the same invariant `callLocal`'s
        // reload already banks on, held loud in all three places it matters.
        const cell = self.actors.getPtr(pending.id).?;
        if (cell.pending_become) |prev| releaseBox(self.allocator, prev);
        cell.pending_become = pending.box;
    }

    /// End one frame of an actor's reentrant run. When the last frame unwinds,
    /// install any promoted `become`: swap the actor's live box for the new one,
    /// releasing the old live reference (a snapshot that shares it keeps it
    /// alive). Deferring the swap to zero depth is what keeps a running outer
    /// frame's `self` valid across a reentrant inner become.
    fn finishCellRun(self: *Vat, id: u64) void {
        // A running actor is never removed (the `callLocal` invariant).
        const cell = self.actors.getPtr(id).?;
        cell.running -= 1;
        if (cell.running != 0) return;
        const next = cell.pending_become orelse return;
        cell.pending_become = null;
        releaseBox(self.allocator, cell.box);
        cell.box = next;
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

    /// Drive `Turn.forward`: forward this turn's call to `target` and dispatch
    /// on the turn's `origin` — the one place the provenance matters.
    ///
    /// A `.local` frame's return value is consumed directly (the near-caller's
    /// reply, or the queued vow's resolution), so it forwards by near-call and
    /// returns the target's value, legal only for a local target, since `near`
    /// refuses a far ref. A `.served` turn defers: with a wire answer it sends
    /// and settles that answer on the forwarded promise; with none (a wire
    /// `tell`) it forwards fire-and-forget. The placeholder return is ignored
    /// by `serve` once `forwarded` is set.
    fn forwardTurn(self: *Vat, turn: *Turn, target: Ref, msg: Message) anyerror!model.Argument {
        const maybe_answer = switch (turn.origin) {
            .local => return self.near(target, msg),
            .served => |maybe_answer| maybe_answer,
        };
        const answer = maybe_answer orelse {
            try self.tell(target, msg);
            turn.forwarded = true;
            return .{ .void = {} };
        };
        const vow = try self.send(target, msg);
        const fc = try self.allocator.create(ForwardContext);
        fc.* = .{ .vat = self, .answer = answer };
        // A fresh vow can only collide on OOM, never `AlreadyListening`.
        self.on(vow, .{ .ctx = fc, .func = forwardListener }) catch |e| {
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

    /// Break every outstanding far vow with `message`, firing each
    /// listener's break path synchronously, before this returns, a
    /// stack-bound listener context is safe because nothing fires later. A far vow settles only when the partner's resolution
    /// arrives over the wire, so once the connection is gone those resolutions can
    /// never come. A driver calls this on disconnect, so an awaiting `on`
    /// listener settles broken instead of waiting forever. `message` is borrowed
    /// for the duration of the calls, so a static string is the norm. Local
    /// vows are untouched: they settle synchronously in `drive` and never
    /// wait on the wire.
    pub fn breakFarVows(self: *Vat, message: []const u8) void {
        // Swap the whole map out before any fire: a listener may react by
        // registering another far vow, which lands in the fresh (live)
        // map and can never invalidate the drained iterator — the same
        // remove-before-fire strength as removing entries one at a time,
        // without the O(n × capacity) fresh key scan per entry. The outer
        // while re-checks, so vows registered during the break also fire
        // broken: once the connection is gone, no resolution can ever come.
        while (self.far_listeners.count() > 0) {
            var taken = self.far_listeners;
            self.far_listeners = .{};
            defer taken.deinit(self.allocator);
            var it = taken.valueIterator();
            while (it.next()) |listener| {
                listener.func(listener.ctx, .{ .broken = message });
            }
        }
    }

    /// Bind an already-spawned local actor to export `position` so a partner's
    /// deliveries to that position run the actor (dispatched by `serve`). Requires
    /// a bound peer. This is the numeric-position primitive; the by-name publish
    /// verb one layer up (`Served.publish`, `BlockingSession.publish`) rides on
    /// it. Binding *reserves* the position, it does not grant it: the partner
    /// can address the actor only once its reference first marshals onto the
    /// wire, or after an explicit `peer.exportObject` grant (ADR-0074). Only a
    /// local actor can be bound — a far ref already lives elsewhere — so a far
    /// ref returns `NotLocal`.
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
        errdefer std.debug.assert(self.exports.remove(position));
        try peer.reserveExport(position);
        gop.value_ptr.* = local_id;
    }

    /// The local `Ref` bound to wire export `position`, or null when no actor is
    /// exported there, the inverse of `bindExport`'s position-to-actor map. A
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
            const resolution: Resolution = if (self.callLocal(queued.target, queued.msg)) |value|
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

    /// Dispatch one inbound peer event: a deliver to a published actor runs its
    /// turn and resolves the answer (`serveDeliver`); a resolve for a far vow
    /// fires its listener (`serveResolve`). Returns whether the event belonged
    /// to this vat; if it did not, the caller handles it. The application polls
    /// the peer and hands events here.
    pub fn serve(self: *Vat, event: *engine.Event) !bool {
        const body = event.view() catch return false;
        return switch (body) {
            .deliver => |deliver| self.serveDeliver(deliver),
            .resolve => |resolve| self.serveResolve(event, resolve),
            else => false,
        };
    }

    /// The deliver arm of `serve`: run the bound actor's turn against the
    /// borrowed wire message and resolve (or break) the inbound answer,
    /// consulting the resolve interceptor on the fulfilled path.
    fn serveDeliver(self: *Vat, deliver: model.view.Deliver) !bool {
        const export_position = deliver.target.exportPosition() orelse return false;
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
                const id = rmd.position() orelse break :blk @as(?model.AnswerPosition, null);
                break :blk peer.answerForResolverImport(model.ImportPosition.from(id));
            }
            break :blk @as(?model.AnswerPosition, null);
        } else null;
        const local_id = self.exports.get(export_position.int()) orelse {
            // The bootstrap position is engine-owned: the peer
            // auto-answers its delivers (`fetch`, gift deposit /
            // withdraw) and only surfaces the event for observation,
            // so the vat must not race a break onto its answer.
            if (export_position.int() == engine.BOOTSTRAP_POSITION) return false;
            // The engine admitted the deliver, so the position IS a
            // granted export at peer level — but no actor is bound
            // (no `bindExport`). An answered call must
            // not strand the partner's vow, so break it, exactly
            // as the mapped-but-vanished case below does. A no-answer
            // `tell` stays a silent no-op the caller may handle.
            if (answer != null) {
                try self.resolveBreak(answer, @errorName(Error.NoSuchActor));
                return true;
            }
            return false;
        };
        // The depth and actor checks run before the turn opens, ordered
        // exactly as `callLocal` orders them, so a refusal never resets
        // the arena or marks a frame running.
        if (self.turn_depth >= max_near_call_depth) {
            try self.resolveBreak(answer, @errorName(Error.NearCallTooDeep));
            return true;
        }
        const cell = self.actors.getPtr(local_id) orelse {
            try self.resolveBreak(answer, @errorName(Error.NoSuchActor));
            return true;
        };
        // Copy-on-write a shared box before the inbound turn can mutate
        // it, ordered with the checks above so a refusal never resets the
        // arena.
        try self.ensureUnshared(cell);
        const box = cell.box;
        cell.running += 1;
        // Materialize the borrowed wire args *inside* the turn window:
        // `beginTurn`'s depth-0 reset has already run, so the args land
        // in the turn arena and the next outermost turn's reset reclaims
        // them — bump-and-reset instead of a per-event allocate/free walk
        // on the vat allocator. The handler contract is already
        // turn-scoped (module header), so nothing may retain them past
        // this window anyway; the reply (which may alias the args) stays
        // valid until the next outermost turn, exactly as documented.
        const arena = self.beginTurn();
        defer self.endTurn();
        // Install any promoted `become` only when this actor's outermost
        // frame unwinds. The reply and the interceptor both read `value`
        // while `running >= 1`, so the box `value` may alias is never
        // freed before the fulfill is sent.
        defer self.finishCellRun(local_id);
        const args = try deliver.args.toOwnedSlice(arena);
        var turn = Turn{ .vat = self, .self_ref = .{ .local = local_id }, .arena = arena, .origin = .{ .served = answer } };
        if (box.handle(box.ptr, &turn, messageFor(args))) |value| {
            if (turn.pending_become) |pending| self.promoteBecome(pending);
            // A moved reply (`Turn.moveOut`) needs nothing here: the vat
            // already holds its bytes, and `resolveFulfill` copies the
            // reply onto the wire inside this turn, before the deferred
            // free. The wire copy is mandatory regardless, so the move
            // saves nothing on the serve path — it only avoids
            // `callLocal`'s sever-copy on the near path.
            // A forwarding actor handed its answer to another send's
            // vow; that vow resolves it, not this return.
            if (turn.forwarded) return true;
            // The interceptor runs inside the turn (`turn_depth >= 1`), so
            // any top-level turn it opens is nested and never resets the
            // arena `value` may live in — the value is turn-borrowed,
            // exactly like a handler's own reply.
            if (self.resolve_interceptor) |interceptor| {
                if (answer) |ans| {
                    const outcome = interceptor.func(interceptor.ctx, ans, value) catch |err| {
                        try self.resolveBreak(answer, @errorName(err));
                        return true;
                    };
                    switch (outcome) {
                        // The interceptor resolved the answer itself
                        // (an originated give); the vat sends nothing.
                        .claimed => {},
                        // Resolve with what it returned — the original
                        // value, or a token rewritten to its wire
                        // reference.
                        .resolve => |reply| try self.resolveFulfill(answer, reply),
                    }
                    return true;
                }
            }
            try self.resolveFulfill(answer, value);
            return true;
        } else |err| {
            if (turn.pending_become) |pending| releaseBox(self.allocator, pending.box);
            try self.resolveBreak(answer, @errorName(err));
            return true;
        }
    }

    /// The no-listener drop shared by the two far-settle spines: remember the
    /// answer (bounded) so a late `on` for this vow is refused
    /// `AlreadySettled` instead of parking forever. A `put` failure or a full
    /// set only forgoes that guard for this one answer, never a fault.
    fn noteServedDrop(self: *Vat, answer: model.AnswerPosition) void {
        if (self.served_dropped_far.count() < max_served_dropped_far_answers) {
            self.served_dropped_far.put(self.allocator, answer, {}) catch {};
        }
    }

    /// The fulfilled-arm settle spine shared by `serveResolve` and
    /// `settleFar`, holding the choreography their prose used to promise
    /// stayed in sync. The clone defends two hazards: a listener may open a
    /// top-level turn (`near` or `drive`) whose depth-0 turn-arena reset
    /// would free a turn-borrowed value mid-call, and the value may borrow
    /// actor state a listener-run turn mutates or `become`-frees. Its home is
    /// the settle arena, not the queue arena — a listener-opened `drive` here
    /// is *outermost*, so its full-drain queue-arena reset would free the
    /// value mid-call — and the depth guard keeps a re-entrant settle (a
    /// listener pumping `serve` again) from resetting the arena under the
    /// outer value. Materialized before the remove so an OOM leaves the
    /// listener parked, not stranded. `value` is either a borrowed
    /// `model.view.Argument` (the wire path) or an owned `model.Argument`
    /// (the byte-fed host path); the clone verb is the only difference.
    fn fireFulfilledFar(self: *Vat, answer: model.AnswerPosition, listener: Listener, value: anytype) !void {
        self.settle_depth += 1;
        defer {
            self.settle_depth -= 1;
            if (self.settle_depth == 0) _ = self.settle_arena.reset(.{ .retain_with_limit = steady_settle_arena_bytes });
        }
        const arena = self.settle_arena.allocator();
        const owned = if (@TypeOf(value) == model.Argument)
            try model.cloneArgument(arena, value)
        else
            try value.toOwned(arena);
        std.debug.assert(self.far_listeners.fetchRemove(answer) != null);
        listener.func(listener.ctx, .{ .fulfilled = owned });
    }

    /// The broken-arm sibling: remove-before-fire, reason borrowed for the
    /// call.
    fn fireBrokenFar(self: *Vat, answer: model.AnswerPosition, listener: Listener, reason: []const u8) void {
        std.debug.assert(self.far_listeners.fetchRemove(answer) != null);
        listener.func(listener.ctx, .{ .broken = reason });
    }

    /// The resolve arm of `serve`: fire the far vow's one-shot listener with
    /// the settled outcome — a typed give projection when the fulfillment
    /// carries a signed handoff give (`event` is here for exactly that: the
    /// verbatim envelope span lives only in the event's frame), an owned clone
    /// on the plain fulfilled path, or the break reason.
    fn serveResolve(self: *Vat, event: *engine.Event, resolve: model.view.Resolve) !bool {
        // Peek the listener rather than remove it: the fulfilled and give
        // arms do fallible allocation before firing, and an error return
        // must leave the entry in the map so teardown
        // (`freeOwnedForwardContexts`) or `breakFarVows` still reclaims
        // it — a `forwardListener` frees its heap `ForwardContext` only
        // when it fires. Each arm removes the entry immediately before it
        // fires, preserving the remove-before-fire order a listener that
        // registers a new far vow relies on.
        const listener = self.far_listeners.get(resolve.answer) orelse {
            self.noteServedDrop(resolve.answer);
            return false;
        };
        switch (resolve.resolution) {
            .fulfill => |value| {
                // A fulfillment carrying a handoff give fires typed:
                // the verbatim envelope span lives only in the event's
                // frame, so this is the one place it can be projected.
                // A give whose envelope or location does not project
                // falls through and fires as the plain argument.
                if (value == .handoff and value.handoff == .give) {
                    if (engine.spanSignedHandoffGive(event.bytes())) |span| {
                        const uri = engine.handoff_recipient.exporterLocatorUri(
                            self.allocator,
                            value.handoff.give.exporter_location,
                        ) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.MalformedLocatorRecord => null,
                        };
                        if (uri) |locator_uri| {
                            defer self.allocator.free(locator_uri);
                            std.debug.assert(self.far_listeners.fetchRemove(resolve.answer) != null);
                            listener.func(listener.ctx, .{ .give = .{
                                .give_bytes = span,
                                .exporter_locator_uri = locator_uri,
                                .recipient_key = value.handoff.give.recipient_key,
                            } });
                            return true;
                        }
                    }
                }
                try self.fireFulfilledFar(resolve.answer, listener, value);
            },
            .@"break" => |reason| self.fireBrokenFar(resolve.answer, listener, reason.message),
        }
        return true;
    }

    /// Settle the far vow at `answer` with `resolution`, firing and removing its
    /// one-shot listener. This is how an embedder that executes node serve-step
    /// actions (`engine.Node.Action.settle` / `.fail`) delivers a settlement
    /// that never crossed this vat's own wire — the byte-fed host's spelling of
    /// the resolve arm of `serve`, minus the wire event. The fulfilled value is
    /// cloned into the settle arena for the listener call, under the same depth
    /// guard as `serveResolve`'s fulfilled arm; a broken reason is borrowed for
    /// the call. With no listener parked, the answer is recorded into
    /// `served_dropped_far` (bounded), the same contract as a wire resolve
    /// served with no listener, so a late `on` is refused `AlreadySettled`
    /// instead of parking forever. The parameter admits no `.give`: the
    /// executor that calls this exists to redeem gives before the vat sees
    /// them, and the narrower type makes that contract unrepresentable rather
    /// than a runtime trap an external caller could hit.
    pub fn settleFar(self: *Vat, answer: model.AnswerPosition, outcome: FarOutcome) Error!void {
        const listener = self.far_listeners.get(answer) orelse return self.noteServedDrop(answer);
        switch (outcome) {
            .fulfilled => |value| try self.fireFulfilledFar(answer, listener, value),
            .broken => |reason| self.fireBrokenFar(answer, listener, reason),
        }
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

    fn resolveFulfill(self: *Vat, answer: ?model.AnswerPosition, reply: model.Argument) !void {
        const ans = answer orelse return;
        const peer = self.peer orelse return;
        try peer.sendCopying(.{ .resolve = .{ .answer = ans, .resolution = .{ .fulfill = reply } } });
    }

    fn resolveBreak(self: *Vat, answer: ?model.AnswerPosition, message: []const u8) !void {
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
