//! A vat: a turn loop over a heap of actors, local and remote alike.
//!
//! This is pancake's Goblins-shaped actor model, expressed in native Zig. It is
//! where local actors meet the OCapN engine. A Vat owns local actors and queued
//! turns; one or more Ports own session-specific wire names and route remote
//! sends. You drive it
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
//! them into an ingress-attributed queue chunk (a queued turn runs at the next
//! `drive`, after the turn arena the caller built them in has been reset), and
//! the far arm clones them inside `peer.sendCopying`. Either way the caller's
//! storage is free the moment the send returns.
//!
//! Two verbs, matching Goblins:
//!   * `Vat.near` is the synchronous near-call (`$`). It runs an actor's handler
//!     immediately and returns its value. It is legal only for a local ref in the
//!     same vat, exactly as Goblins forbids `$` to a far ref.
//!   * `Port.send` is eventual send (`<-`). A local ref queues a Vat turn; a far
//!     ref sends `op:deliver` over that Port. Either way it returns a `Vow`.
//!
//! A `Vow` is observed with `Vat.on` and has no matching `off`. A listener fires
//! exactly once, when the vow settles or when `breakFarVows` breaks every far vow
//! on disconnect, so there is nothing to cancel: dropping interest before a settle
//! is the break path's job, not a listener removal.
//!
//! The unified `Ref` can name a local actor or a far object, and a `Vow`
//! can settle from a local turn or from a wire answer. An application sends to a
//! ref without caring where it lives; the vat chooses the route. The engine stays
//! focused on codecs and authority. The vat sits above it and imports the engine,
//! never the reverse.
//!
//! ## Local time-travel (snapshot / restore)
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
//! it never touches `peer`, `exports`, far listeners, or the turn
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
// engine's `steady_queue_bytes` posture (src/ocapn/engine/mod.zig). A Vat
// retains one spare queue chunk globally, never one per ingress; its payload
// arena keeps at most the bound below so ordinary traffic stays allocation-free
// after warming while burst chunks reclaim incrementally. Recorded in
// .agents/rules/memory.md's footprint budget. File-level (not `Vat` decls) so
// sibling vat modules share them without widening the public surface.
/// Turn-arena bound, applied at the outermost-turn reset in `turn.beginTurn`.
pub const steady_turn_arena_bytes = 4096;
/// Payload-arena bound for the Vat-wide spare queue chunk.
pub const steady_spare_arena_bytes = 4096;
/// Settle-arena bound, applied at the depth-0 reset in the far-resolve settle.
pub const steady_settle_arena_bytes = 4096;
/// Backing bound for plain ArrayLists such as `moved_replies`, and the target
/// size of one queue chunk's fixed row array.
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

    /// What an argument accessor refuses. A handler returns these like any
    /// other error, and the vat turns a handler error into the partner's
    /// `op:resolve` break, so a malformed call breaks its own answer instead
    /// of reaching the host.
    pub const ArgError = error{ MissingArgument, WrongArgumentType };

    /// The argument at `i`, or `MissingArgument`.
    ///
    /// Arity is the *partner's* choice: `serve` peels the leading symbol as the
    /// verb and hands the rest through, so a deliver carrying only a verb
    /// arrives with no arguments at all. An unchecked index on that is a safety
    /// panic in a safe build and an out-of-bounds read otherwise, which on a
    /// multi-session host takes down every other session with it. The typed
    /// accessors below are shorter to write than the unwrap they replace, so
    /// there is no cheaper wrong path left; `msg.args` is still there for a
    /// handler that has already checked `args.len`.
    pub fn arg(self: Message, i: usize) ArgError!model.Argument {
        if (i >= self.args.len) return error.MissingArgument;
        return self.args[i];
    }

    /// The `bytes` argument at `i`.
    pub fn argBytes(self: Message, i: usize) ArgError![]const u8 {
        return switch (try self.arg(i)) {
            .bytes => |b| b,
            else => error.WrongArgumentType,
        };
    }

    /// The `string` argument at `i`.
    pub fn argString(self: Message, i: usize) ArgError![]const u8 {
        return switch (try self.arg(i)) {
            .string => |s| s,
            else => error.WrongArgumentType,
        };
    }

    /// The `integer` argument at `i`.
    pub fn argInt(self: Message, i: usize) ArgError!i64 {
        return switch (try self.arg(i)) {
            .integer => |n| n,
            else => error.WrongArgumentType,
        };
    }
};

/// One causal source of queued turns. `.local` is the pure-local/application
/// source; a composed Host mints one additional id per session Port. The Vat
/// owns ids so two adapters cannot accidentally share accounting.
pub const IngressId = enum(u32) {
    local = 0,
    _,
};

/// Atomic admission limits for each ingress. `max_pending_bytes` charges the
/// exact requested payload bytes of the owned message clone plus its queue row;
/// allocator metadata and bounded chunk slack are held separately by footprint
/// tests. A single message must also fit `max_chunk_bytes`, so no exceptional
/// oversized chunk bypasses incremental reclamation.
pub const QueueLimits = struct {
    max_pending_turns: u32 = 4096,
    max_pending_bytes: u32 = 1024 * 1024,
    max_chunk_bytes: u32 = 64 * 1024,
};

const Queued = struct {
    target: u64,
    msg: Message,
    vow: u64,
    charged_bytes: u32,
    /// Port whose authority caused this turn, or null for pure-local work.
    port: ?*Port,
};

/// Queue metadata is bounded independently of message payload. A chunk owns
/// one arena for at most this many turns and is released as soon as its last
/// turn finishes, even while other ingress work remains.
const queue_chunk_turns = @max(1, steady_list_bytes / @sizeOf(Queued));

const QueueChunk = struct {
    next: ?*QueueChunk = null,
    arena: std.heap.ArenaAllocator,
    items: [queue_chunk_turns]Queued = undefined,
    head: usize = 0,
    len: usize = 0,
    owned_bytes: u32 = 0,
    /// Turns currently borrowing messages from this chunk. A nested drive may
    /// exhaust the remaining rows while an outer handler still reads an earlier
    /// row, so exhaustion detaches the chunk but reclamation waits for this to
    /// reach zero.
    active_turns: u32 = 0,
};

const IngressState = struct {
    id: IngressId,
    first: ?*QueueChunk = null,
    last: ?*QueueChunk = null,
    pending_turns: u32 = 0,
    pending_bytes: u32 = 0,
    active_turns: u32 = 0,
    runnable_next: ?*IngressState = null,
    runnable: bool = false,
};

/// A local vow name in this Vat's monotonic, never-reused epoch. Keeping the
/// map key distinct prevents a wire answer position or another bare integer
/// namespace from being used here by accident.
const PendingLocalVowKey = struct { id: u64 };

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
    /// `drive` ran its turn). Local vows settle exactly once; a listener
    /// registered afterwards could never fire, so failing loud beats parking
    /// it forever. Fair ingress rotation means settlement is not globally FIFO.
    AlreadySettled,
    /// A local value tree deep-copied into the queue or a settle nested past
    /// `model.max_value_depth`. Copying an actor's arguments walks the tree
    /// recursively, so the model-layer depth ceiling caps that walk here too,
    /// failing loud rather than overflowing the native stack. Real handler
    /// arguments never reach it; a pathologically nested local value does.
    MalformedView,
    /// A local enqueue would exceed its ingress's pending-turn, pending-byte,
    /// or single-chunk byte limit. Admission happens before cloning or queue
    /// mutation, so this refusal never leaves a partial turn behind.
    ResourceExhausted,
    /// An ingress id was not minted by this Vat, or was already closed.
    UnknownIngress,
    /// Closing an ingress was attempted while it still had queued or running
    /// turns. Its accounting remains live until both reach zero.
    IngressBusy,
} || std.mem.Allocator.Error;

/// One CapTP session's projection of a Vat: wire peer, export positions, and
/// far-vow settlement. A Port owns names and authority that exist only on that
/// session; the Vat owns the actor graph and turn machinery shared by every
/// Port attached to it.
pub const Port = struct {
    allocator: std.mem.Allocator,
    /// Borrowed from the Node that owns this session's Peer allocation.
    peer: *engine.Peer,
    /// Causal/admission identity in the Vat. Standalone Ports use `.local`;
    /// a multi-Port Host assigns one minted ingress per session.
    ingress: IngressId = .local,
    resolve_interceptor: ?ResolveInterceptor = null,
    /// Listener for a far send's vow, keyed by this Port's outbound answer
    /// position namespace.
    far_listeners: std.AutoHashMapUnmanaged(model.AnswerPosition, Listener) = .{},
    /// Answers served before a listener was registered. Bounded; see
    /// `max_served_dropped_far_answers`.
    served_dropped_far: std.AutoHashMapUnmanaged(model.AnswerPosition, void) = .{},
    /// Local actor id for each export position projected on this Port.
    exports: std.AutoHashMapUnmanaged(u64, u64) = .{},
    /// Canonical export position already projecting a local actor.
    reverse_exports: std.AutoHashMapUnmanaged(u64, u64) = .{},

    pub fn init(allocator: std.mem.Allocator, peer: *engine.Peer) Port {
        return .{ .allocator = allocator, .peer = peer };
    }

    pub fn deinit(self: *Port) void {
        freeOwnedForwardContexts(self.allocator, &self.far_listeners);
        self.far_listeners.deinit(self.allocator);
        self.served_dropped_far.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        self.reverse_exports.deinit(self.allocator);
        self.* = undefined;
    }

    /// Install (or clear) the fulfilled-reply interceptor for this session.
    pub fn setResolveInterceptor(self: *Port, interceptor: ?ResolveInterceptor) void {
        self.resolve_interceptor = interceptor;
    }

    /// Location-transparent eventual-send through this session projection.
    pub fn send(self: *Port, vat: *Vat, target: Ref, msg: Message) Error!Vow {
        return self.sendFromIngress(vat, self.ingress, target, msg);
    }

    pub fn sendFromIngress(self: *Port, vat: *Vat, ingress: IngressId, target: Ref, msg: Message) Error!Vow {
        if (ingress != self.ingress) return Error.UnknownIngress;
        _ = try vat.ingressState(ingress);
        return switch (target) {
            .local => |id| .{ .local = try vat.enqueueLocal(ingress, self, id, msg) },
            .far => |far| self.sendFarTo(vat, .{ .far = far }, msg),
        };
    }

    fn sendFarTo(self: *Port, vat: *Vat, target: model.Reference, msg: Message) Error!Vow {
        const answer = model.AnswerPosition.from(self.peer.allocateAnswer());
        try vat.farDeliverTo(self, target, msg, answer);
        return .{ .far = answer };
    }

    /// Promise-pipelined eventual-send through this Port's answer namespace.
    pub fn sendToAnswer(self: *Port, vat: *Vat, answer: model.AnswerPosition, msg: Message) Error!Vow {
        return self.sendFarTo(vat, .{ .promise = .{ .answer_position = answer } }, msg);
    }

    pub fn tell(self: *Port, vat: *Vat, target: Ref, msg: Message) Error!void {
        return self.tellFromIngress(vat, self.ingress, target, msg);
    }

    pub fn tellFromIngress(self: *Port, vat: *Vat, ingress: IngressId, target: Ref, msg: Message) Error!void {
        if (ingress != self.ingress) return Error.UnknownIngress;
        _ = try vat.ingressState(ingress);
        switch (target) {
            .local => |id| _ = try vat.enqueueLocal(ingress, self, id, msg),
            .far => |far| try vat.farDeliverTo(self, .{ .far = far }, msg, null),
        }
    }

    /// Observe a local Vat vow or a far vow in this Port's answer namespace.
    pub fn on(self: *Port, vat: *Vat, vow: Vow, listener: Listener) Error!void {
        switch (vow) {
            .local => try vat.on(vow, listener),
            .far => |answer| {
                if (self.served_dropped_far.contains(answer)) return Error.AlreadySettled;
                const gop = try self.far_listeners.getOrPut(self.allocator, answer);
                if (gop.found_existing) return Error.AlreadyListening;
                gop.value_ptr.* = listener;
            },
        }
    }

    /// Dispatch one inbound event under this Port's causal ingress.
    pub fn serveFromIngress(self: *Port, vat: *Vat, ingress: IngressId, event: *engine.Event) !bool {
        if (ingress != self.ingress) return Error.UnknownIngress;
        const state = try vat.ingressState(ingress);
        state.active_turns += 1;
        defer state.active_turns -= 1;
        return serve_mod.serveFromIngress(vat, self, ingress, event);
    }

    pub fn serve(self: *Port, vat: *Vat, event: *engine.Event) !bool {
        return self.serveFromIngress(vat, self.ingress, event);
    }

    pub fn settleFar(self: *Port, vat: *Vat, answer: model.AnswerPosition, outcome: FarOutcome) Error!void {
        return serve_mod.settleFar(vat, self, answer, outcome);
    }

    pub fn breakFarVows(self: *Port, message: []const u8) void {
        serve_mod.breakFarVows(self, message);
    }

    pub fn bindExport(self: *Port, actor: Ref, position: u64) !void {
        return serve_mod.bindExport(self, actor, position);
    }

    pub fn refForExport(self: *const Port, position: u64) ?Ref {
        return serve_mod.refForExport(self, position);
    }

    pub fn projectionForActor(self: *const Port, actor: Ref) ?model.NearRef {
        const actor_id = switch (actor) {
            .local => |id| id,
            .far => return null,
        };
        const position = self.reverse_exports.get(actor_id) orelse return null;
        return model.NearRef.object(position);
    }

    pub const Projection = struct {
        near: model.NearRef,
        created: bool,
    };

    /// Undo a bind that never became shared with the partner.
    pub fn rollbackExport(self: *Port, actor: Ref, position: u64) void {
        const actor_id = switch (actor) {
            .local => |id| id,
            .far => unreachable,
        };
        std.debug.assert(self.exports.get(position).? == actor_id);
        std.debug.assert(self.exports.remove(position));
        if (self.reverse_exports.get(actor_id) == position) {
            var replacement: ?u64 = null;
            var it = self.exports.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == actor_id) {
                    replacement = entry.key_ptr.*;
                    break;
                }
            }
            if (replacement) |other|
                self.reverse_exports.getPtr(actor_id).?.* = other
            else
                std.debug.assert(self.reverse_exports.remove(actor_id));
        }
        self.peer.session_state.releaseUnsharedExport(.from(position));
    }

    /// Reuse or lazily mint this Port's canonical wire position for `actor`,
    /// reporting whether this call created the row. The receipt lets a caller
    /// whose larger transaction later fails roll back only authority it minted.
    pub fn prepareProjection(self: *Port, actor: Ref) !Projection {
        const actor_id = switch (actor) {
            .local => |id| id,
            .far => return Error.NotLocal,
        };
        if (self.reverse_exports.get(actor_id)) |position| return .{
            .near = model.NearRef.object(position),
            .created = false,
        };
        const position = try self.peer.exportNextObject();
        errdefer self.peer.session_state.releaseUnsharedExport(.from(position));
        try self.bindExport(actor, position);
        return .{
            .near = model.NearRef.object(position),
            .created = true,
        };
    }

    /// Reuse or lazily mint this Port's canonical wire position for `actor`.
    pub fn projectActor(self: *Port, actor: Ref) !model.NearRef {
        return (try self.prepareProjection(actor)).near;
    }
};

fn freeOwnedForwardContexts(allocator: std.mem.Allocator, map: anytype) void {
    var it = map.valueIterator();
    while (it.next()) |listener| {
        if (listener.func == serve_mod.forwardListener) {
            const fc: *serve_mod.ForwardContext = @ptrCast(@alignCast(listener.ctx.?));
            allocator.destroy(fc);
        }
    }
}

/// One single-threaded container of local objects, the Goblins-shaped layer
/// above the engine. Spawn objects, near-call them with `near` (`$`),
/// eventual-send with `send` (`<-`), and `drive` queued turns to completion;
/// attach Ports and the same sends reach far references. Sync and no-I/O by
/// contract (ADR-0036). Everything spawned or queued lives on the vat's
/// allocator and arenas, freed in `deinit`.
pub const Vat = struct {
    allocator: std.mem.Allocator,
    actors: std.AutoHashMapUnmanaged(u64, Cell) = .{},
    queue_limits: QueueLimits = .{},
    local_ingress: IngressState = .{ .id = .local },
    /// Non-local ingress rows are heap-pinned so the intrusive runnable ring
    /// stays pointer-stable while the hash map grows inside a running turn.
    ingresses: std.AutoHashMapUnmanaged(IngressId, *IngressState) = .{},
    runnable_head: ?*IngressState = null,
    runnable_tail: ?*IngressState = null,
    /// One Vat-wide spare amortizes ordinary local enqueue without retaining a
    /// chunk per idle ingress. Every additional completed chunk is freed.
    spare_chunk: ?*QueueChunk = null,
    listeners: std.AutoHashMapUnmanaged(u64, Listener) = .{},
    /// Local vows whose turns are still pending. Fair ingress rotation can
    /// settle vow ids out of global numeric order, so the old FIFO high-water
    /// mark is unsound; this index makes late-listener refusal independent of
    /// scheduling order.
    pending_local_vows: std.AutoHashMapUnmanaged(PendingLocalVowKey, void) = .{},
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
    /// reply and scratch live here; the vat reclaims the whole arena when its next
    /// outermost turn begins (when `turn_depth` returns to 0 and rises again), so a
    /// reply stays valid until then and no handler frees or leaks its own reply.
    turn_arena: std.heap.ArenaAllocator,
    /// Nesting depth of in-flight turns. The turn arena resets only at depth 0, so a
    /// near-call or send made inside a turn shares that turn's scratch rather than
    /// pulling it out from under the call in flight.
    turn_depth: u32 = 0,
    /// Nesting depth of in-flight `drive` calls. A listener may open a nested
    /// drive; the runnable ring is Vat-owned so nested drives continue from the
    /// fair rotation point rather than re-running the active turn.
    drive_depth: u32 = 0,
    next_ingress: u32 = 1,
    /// Scratch for local and far fulfilled-listener calls. Queue chunks may
    /// reclaim independently, so settlement has one depth-guarded arena that a
    /// listener-opened drive cannot reset under the borrowed value.
    settle_arena: std.heap.ArenaAllocator,
    /// Nesting depth of in-flight far-resolve settles. A far listener can
    /// re-enter `serve` (a driver pump: `BlockingSession.step` then `drainEvents`),
    /// and the nested settle must not reset the arena the outer listener's
    /// value still lives in; only the return to depth 0 resets it.
    settle_depth: u32 = 0,
    next_actor: u64 = 1,
    next_vow: u64 = 1,
    /// Reply bytes handlers moved to the vat via `Turn.moveOut`, awaiting free.
    /// They share the turn arena's lifetime: the vat frees them when its next
    /// outermost turn begins, so a moved reply stays valid for the caller until
    /// then — with no copy, since the handler already owned the bytes.
    moved_replies: std.ArrayList([]const u8) = .empty,
    /// State boxes a `become` has swapped out of their actor, awaiting their
    /// last reference to drop. Held to the same boundary as `moved_replies`,
    /// and for the same reason: a handler may return a reply that borrows the
    /// state it ran as, and that reply stays valid until the vat's next
    /// outermost turn. The frame that installs a become can sever its own
    /// reply, but not one an *earlier* frame of the same actor already handed
    /// back to a caller still running; that frame has closed. Freeing the box
    /// here instead of at the install makes both replies outlive it.
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
            .queue_limits = options.queue_limits,
            .turn_arena = std.heap.ArenaAllocator.init(allocator),
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
        self.freeIngressQueue(&self.local_ingress);
        var ingress_it = self.ingresses.valueIterator();
        while (ingress_it.next()) |state_ptr| {
            self.freeIngressQueue(state_ptr.*);
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
        freeOwnedForwardContexts(self.allocator, &self.listeners);
        self.listeners.deinit(self.allocator);
        self.pending_local_vows.deinit(self.allocator);
        turn_mod.drainMovedReplies(self);
        self.moved_replies.deinit(self.allocator);
        turn_mod.drainRetiredBoxes(self);
        self.retired_boxes.deinit(self.allocator);
        self.turn_arena.deinit();
        self.settle_arena.deinit();
    }

    fn ingressState(self: *Vat, ingress: IngressId) Error!*IngressState {
        if (ingress == .local) return &self.local_ingress;
        return self.ingresses.get(ingress) orelse Error.UnknownIngress;
    }

    fn acquireQueueChunk(self: *Vat) std.mem.Allocator.Error!*QueueChunk {
        if (self.spare_chunk) |chunk| {
            self.spare_chunk = null;
            const arena = chunk.arena;
            chunk.* = .{ .arena = arena };
            return chunk;
        }
        const chunk = try self.allocator.create(QueueChunk);
        chunk.* = .{ .arena = std.heap.ArenaAllocator.init(self.allocator) };
        return chunk;
    }

    fn releaseQueueChunk(self: *Vat, chunk: *QueueChunk) void {
        std.debug.assert(chunk.next == null);
        std.debug.assert(chunk.active_turns == 0);
        if (self.spare_chunk == null) {
            _ = chunk.arena.reset(.{ .retain_with_limit = steady_spare_arena_bytes });
            const arena = chunk.arena;
            chunk.* = .{ .arena = arena };
            self.spare_chunk = chunk;
            return;
        }
        chunk.arena.deinit();
        self.allocator.destroy(chunk);
    }

    fn freeIngressQueue(self: *Vat, state: *IngressState) void {
        var maybe_chunk = state.first;
        while (maybe_chunk) |chunk| {
            maybe_chunk = chunk.next;
            chunk.arena.deinit();
            self.allocator.destroy(chunk);
        }
        state.first = null;
        state.last = null;
        state.pending_turns = 0;
        state.pending_bytes = 0;
    }

    fn makeRunnable(self: *Vat, state: *IngressState) void {
        if (state.runnable or state.pending_turns == 0) return;
        state.runnable = true;
        state.runnable_next = null;
        if (self.runnable_tail) |tail| tail.runnable_next = state else self.runnable_head = state;
        self.runnable_tail = state;
    }

    fn takeRunnable(self: *Vat) ?*IngressState {
        const state = self.runnable_head orelse return null;
        self.runnable_head = state.runnable_next;
        if (self.runnable_head == null) self.runnable_tail = null;
        state.runnable_next = null;
        state.runnable = false;
        return state;
    }

    fn takeSpecificRunnable(self: *Vat, wanted: *IngressState) bool {
        if (!wanted.runnable) return false;
        var previous: ?*IngressState = null;
        var current = self.runnable_head;
        while (current) |state| : (current = state.runnable_next) {
            if (state == wanted) {
                if (previous) |prev| prev.runnable_next = state.runnable_next else self.runnable_head = state.runnable_next;
                if (self.runnable_tail == state) self.runnable_tail = previous;
                state.runnable_next = null;
                state.runnable = false;
                return true;
            }
            previous = state;
        }
        unreachable;
    }

    fn finishQueueTurn(self: *Vat, chunk: *QueueChunk) void {
        std.debug.assert(chunk.active_turns > 0);
        chunk.active_turns -= 1;
        if (chunk.head == chunk.len and chunk.active_turns == 0) self.releaseQueueChunk(chunk);
    }

    /// Spawn a local actor with `initial` state, returning a local `Ref`. No
    /// export position is minted: the actor has no wire position at all until
    /// it is bound with `bindExport` (or spawned through the driver's
    /// exporting `spawn`), and even a bound position stays unaddressable
    /// until its reference first marshals onto the wire. `initial` is
    /// consumed on every outcome: on failure its resources are reclaimed
    /// through the state's `deinit`, so the caller never frees it.
    pub fn spawn(self: *Vat, comptime Behavior: type, initial: Behavior) Error!Ref {
        return self.registerBox(try boxed.makeBox(self, Behavior, initial));
    }

    /// Enroll a freshly minted `box` as the next actor and return its local ref.
    /// The one registration tail `spawn` and `spawnHosted` share; it adopts the
    /// box (releasing it if the table insert fails, so the caller never frees a
    /// box it handed over).
    fn registerBox(self: *Vat, box: *StateBox) Error!Ref {
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
        return self.registerBox(try boxed.makeHostedBox(self, hosted));
    }

    /// Roll back a freshly spawned actor that failed before any export binding
    /// or application reference became observable. The caller must hold the
    /// exact `Ref` returned by `spawn`/`spawnHosted` and call this only on that
    /// operation's unwind; actor ids remain monotonic and are not reused.
    pub fn discardFreshActor(self: *Vat, actor: Ref) void {
        const id = switch (actor) {
            .local => |local| local,
            .far => unreachable,
        };
        const removed = self.actors.fetchRemove(id) orelse unreachable;
        std.debug.assert(removed.value.pending_become == null);
        releaseBox(self.allocator, removed.value.box);
    }

    pub fn hasActor(self: *const Vat, id: u64) bool {
        return self.actors.contains(id);
    }

    /// The synchronous near-call (`$`): run `target`'s handler now and return its
    /// value. Legal only for a local ref; a far ref must be reached with `send`.
    /// The returned `Argument` is borrowed from the actor's state or the message
    /// (see the module header) and is valid only as long as both are; a caller
    /// that keeps it copies first.
    pub fn near(self: *Vat, target: Ref, msg: Message) anyerror!model.Argument {
        return self.nearFromIngress(.local, target, msg);
    }

    pub fn nearFromIngress(self: *Vat, ingress: IngressId, target: Ref, msg: Message) anyerror!model.Argument {
        return self.nearFromPort(null, ingress, target, msg);
    }

    pub fn nearFromPort(self: *Vat, port: ?*Port, ingress: IngressId, target: Ref, msg: Message) anyerror!model.Argument {
        const state = try self.ingressState(ingress);
        state.active_turns += 1;
        defer state.active_turns -= 1;
        return switch (target) {
            .local => |id| turn_mod.callLocal(self, port, ingress, id, msg),
            .far => Error.NotNearCallable,
        };
    }

    /// Mint a non-local ingress row. Each Host Port owns one such id; a
    /// pure-local caller can use several to isolate admission and scheduling.
    pub fn openIngress(self: *Vat) Error!IngressId {
        if (self.next_ingress == std.math.maxInt(u32)) return Error.ResourceExhausted;
        const id: IngressId = @enumFromInt(self.next_ingress);
        const state = try self.allocator.create(IngressState);
        errdefer self.allocator.destroy(state);
        state.* = .{ .id = id };
        try self.ingresses.put(self.allocator, id, state);
        self.next_ingress += 1;
        return id;
    }

    /// Release an empty, inactive non-local ingress. Pending or running work is
    /// authority: closing it early would erase accounting and reorder turns.
    pub fn closeIngress(self: *Vat, ingress: IngressId) Error!void {
        if (ingress == .local) return Error.IngressBusy;
        const state = self.ingresses.get(ingress) orelse return Error.UnknownIngress;
        if (state.pending_turns != 0 or state.active_turns != 0 or state.runnable) return Error.IngressBusy;
        std.debug.assert(state.first == null and state.last == null);
        std.debug.assert(self.ingresses.remove(ingress));
        self.allocator.destroy(state);
    }

    /// Tear down a session ingress that can no longer run. It is removed from
    /// admission and fair scheduling before listeners fire, so a break handler
    /// cannot enqueue fresh work onto the closing Port. Every queued local vow
    /// settles broken; unobserved turns are discarded with their chunk.
    pub fn cancelIngress(self: *Vat, ingress: IngressId, reason: []const u8) Error!void {
        if (ingress == .local) return Error.IngressBusy;
        const state = self.ingresses.get(ingress) orelse return Error.UnknownIngress;
        if (state.active_turns != 0) return Error.IngressBusy;
        std.debug.assert(self.ingresses.remove(ingress));

        _ = self.takeSpecificRunnable(state);

        var maybe_chunk = state.first;
        while (maybe_chunk) |chunk| : (maybe_chunk = chunk.next) {
            std.debug.assert(chunk.active_turns == 0);
            for (chunk.items[chunk.head..chunk.len]) |queued| {
                std.debug.assert(self.pending_local_vows.remove(.{ .id = queued.vow }));
                if (self.listeners.fetchRemove(queued.vow)) |entry|
                    entry.value.func(entry.value.ctx, .{ .broken = reason });
            }
        }
        self.freeIngressQueue(state);
        self.allocator.destroy(state);
    }

    /// The eventual send (`<-`): location-transparent. A local target queues a
    /// turn for `drive`; a far target sends an `op:deliver` over the bound peer
    /// (a leading symbol carries the verb, matching Goblins's `($ obj 'method …)`).
    /// Returns a `Vow` for the result. The message's verb and args are
    /// borrowed only for the duration of this call: the local arm clones them
    /// into one ingress queue chunk, the far arm clones them inside
    /// `peer.sendCopying`.
    pub fn send(self: *Vat, target: Ref, msg: Message) Error!Vow {
        return self.sendFromIngress(.local, target, msg);
    }

    pub fn sendFromIngress(self: *Vat, ingress: IngressId, target: Ref, msg: Message) Error!Vow {
        _ = try self.ingressState(ingress);
        switch (target) {
            .local => |id| return .{ .local = try self.enqueueLocal(ingress, null, id, msg) },
            .far => return Error.NotConnected,
        }
    }

    /// The fire-and-forget eventual-send (Goblins `<-np`): like `send`, but it
    /// requests no answer, so the partner's actor runs and sends no reply. A far
    /// `tell` puts one `op:deliver` with no answer on the wire. That is the
    /// right shape for a notification or broadcast, which would otherwise pay for
    /// a reply nobody reads. A local `tell` queues a turn whose result is
    /// discarded. Returns nothing: there is no vow to observe.
    pub fn tell(self: *Vat, target: Ref, msg: Message) Error!void {
        return self.tellFromIngress(.local, target, msg);
    }

    pub fn tellFromIngress(self: *Vat, ingress: IngressId, target: Ref, msg: Message) Error!void {
        _ = try self.ingressState(ingress);
        switch (target) {
            // Queue a turn like `send`, but discard the vow id: it keeps the
            // queue entry uniform and `drive` settles it into no listener.
            .local => |id| _ = try self.enqueueLocal(ingress, null, id, msg),
            .far => return Error.NotConnected,
        }
    }

    /// The one local-enqueue spine `send` and `tell` share. Admission computes
    /// the whole logical ownership charge before cloning; every mutation after
    /// a successful clone is infallible, so refusal never partially enqueues.
    fn enqueueLocal(self: *Vat, ingress: IngressId, port: ?*Port, id: u64, msg: Message) Error!u64 {
        const state = try self.ingressState(ingress);
        const args_bytes = model.measureArgumentSliceOwnedBytes(msg.args) catch return Error.MalformedView;
        var charge = std.math.add(usize, @sizeOf(Queued), msg.verb.len) catch return Error.ResourceExhausted;
        charge = std.math.add(usize, charge, args_bytes) catch return Error.ResourceExhausted;
        const limits = self.queue_limits;
        if (charge > limits.max_chunk_bytes or charge > std.math.maxInt(u32)) return Error.ResourceExhausted;
        const charge32: u32 = @intCast(charge);
        if (state.pending_turns >= limits.max_pending_turns) return Error.ResourceExhausted;
        if (state.pending_bytes > limits.max_pending_bytes or charge32 > limits.max_pending_bytes - state.pending_bytes)
            return Error.ResourceExhausted;
        try self.pending_local_vows.ensureUnusedCapacity(self.allocator, 1);

        var chunk = state.last;
        var acquired = false;
        if (chunk == null or chunk.?.len == queue_chunk_turns or
            chunk.?.owned_bytes > limits.max_chunk_bytes - charge32)
        {
            chunk = try self.acquireQueueChunk();
            acquired = true;
        }
        const owned = self.cloneForQueue(chunk.?, msg) catch |err| {
            if (acquired) self.releaseQueueChunk(chunk.?);
            return err;
        };
        const vow = self.next_vow;
        if (acquired) {
            if (state.last) |last| last.next = chunk else state.first = chunk;
            state.last = chunk;
        }
        chunk.?.items[chunk.?.len] = .{ .target = id, .msg = owned, .vow = vow, .charged_bytes = charge32, .port = port };
        chunk.?.len += 1;
        chunk.?.owned_bytes += charge32;
        state.pending_turns += 1;
        state.pending_bytes += charge32;
        self.pending_local_vows.putAssumeCapacity(.{ .id = vow }, {});
        self.makeRunnable(state);
        self.next_vow += 1;
        return vow;
    }

    /// Clone `msg` into its vat-owned queue chunk: the one named boundary copy
    /// of the local eventual-send path, symmetric with the far path's clone
    /// inside `peer.sendCopying`. A queued message must outlive the sender's
    /// turn — the drive that runs it begins by resetting the very turn arena
    /// the documented handler pattern builds outgoing args in — so the queue
    /// owns its bytes. Its chunk is reclaimed immediately after that chunk's
    /// last turn, independent of every other ingress.
    fn cloneForQueue(self: *Vat, chunk: *QueueChunk, msg: Message) Error!Message {
        _ = self;
        const arena = chunk.arena.allocator();
        return .{
            .verb = try arena.dupe(u8, msg.verb),
            .args = try model.cloneArgumentSlice(arena, msg.args),
        };
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
    fn farDeliverTo(self: *Vat, port: *Port, target: model.Reference, msg: Message, answer: ?model.AnswerPosition) Error!void {
        const peer = port.peer;
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
                if (id < self.next_vow and !self.pending_local_vows.contains(.{ .id = id })) return Error.AlreadySettled;
                const gop = try self.listeners.getOrPut(self.allocator, id);
                if (gop.found_existing) return Error.AlreadyListening;
                gop.value_ptr.* = listener;
            },
            .far => return Error.NotConnected,
        }
    }

    /// Capture the local actor heap (see `boxed.snapshot`).
    pub const snapshot = boxed.snapshot;
    /// Rewind the local actor heap to a snapshot (see `boxed.restore`).
    pub const restore = boxed.restore;

    /// The most local eventual-send turns one inbound batch may drive on a loop
    /// host before the vat is treated as a runaway. A handler's local work
    /// settles in one batch — a legitimate fan-out or chain is far under this —
    /// so the loop drives each batch's queue to completion, keeping no
    /// cross-batch residual. Independently reclaimable chunks bound the retained
    /// queue storage while it does so. A
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
        /// Every ingress queue drained fully within the budget.
        drained,
        /// The budget was spent with turns still queued. The next call resumes
        /// at the head of the fair runnable ring.
        more_pending,
    };

    /// Run queued local eventual-sends to quiescence, settling each vow with
    /// the handler's value (or a break on error) and firing its listener. Turns
    /// queued by a turn run in the same drive. FIFO holds within one ingress;
    /// runnable ingresses rotate one turn at a time.
    pub fn drive(self: *Vat) Error!void {
        _ = try self.driveBudgeted(std.math.maxInt(usize));
    }

    /// Like `drive`, but runs at most `max_turns` queued local turns, then
    /// yields `.more_pending` with every ingress queue intact (a later call
    /// resumes at the fair ring head). A vat whose handlers re-send to
    /// themselves without bound makes `drive` never return; on a loop host
    /// that would starve every other connection the loop serves. `driveBudgeted`
    /// gives the loop host a bound to act on: it drives each inbound batch to
    /// `.drained` and treats `.more_pending` as a runaway amplification, closing
    /// that connection (see `max_batch_local_turns`). The connection-per-thread
    /// `BlockingSession` keeps the unbounded `drive` by contract: it serves one
    /// partner, so a self-send chain there starves only itself.
    ///
    /// Call this at the top level (the loop host's per-connection drive point),
    /// not re-entrantly: a nested full `drive` a listener opens runs to
    /// quiescence by its own contract, draining past this budget.
    pub fn driveBudgeted(self: *Vat, max_turns: usize) Error!DriveProgress {
        // A *finite* budget must not nest (the documented contract above): a
        // nested full `drive` (a listener's) is legal and runs unbudgeted.
        std.debug.assert(max_turns == std.math.maxInt(usize) or self.drive_depth == 0);
        self.drive_depth += 1;
        defer self.drive_depth -= 1;
        var ran: usize = 0;
        while (ran < max_turns) {
            const state = self.takeRunnable() orelse break;
            ran += 1;
            try self.runQueuedTurn(state);
        }
        return if (self.runnable_head == null) .drained else .more_pending;
    }

    /// Drive only one causal ingress. A Host invokes this at a Port's batch
    /// boundary so work enqueued onto a sibling remains attributed to that
    /// sibling's own budget and close policy.
    pub fn driveIngressBudgeted(self: *Vat, ingress: IngressId, max_turns: usize) Error!DriveProgress {
        std.debug.assert(max_turns == std.math.maxInt(usize) or self.drive_depth == 0);
        const state = try self.ingressState(ingress);
        self.drive_depth += 1;
        defer self.drive_depth -= 1;
        var ran: usize = 0;
        while (ran < max_turns and self.takeSpecificRunnable(state)) : (ran += 1)
            try self.runQueuedTurn(state);
        return if (state.pending_turns == 0) .drained else .more_pending;
    }

    fn runQueuedTurn(self: *Vat, state: *IngressState) Error!void {
        const chunk = state.first orelse unreachable;
        std.debug.assert(chunk.head < chunk.len);
        const queued = chunk.items[chunk.head];
        chunk.head += 1;
        state.pending_turns -= 1;
        state.pending_bytes -= queued.charged_bytes;
        if (chunk.head == chunk.len) {
            state.first = chunk.next;
            if (state.first == null) state.last = null;
            chunk.next = null;
        }
        // Rotate before running the handler. A nested drive therefore sees
        // the next ingress, while a causal send from this turn appends this
        // ingress once at the tail if it had become empty.
        self.makeRunnable(state);
        state.active_turns += 1;
        chunk.active_turns += 1;
        const resolution: Resolution = if (turn_mod.callLocal(self, queued.port, state.id, queued.target, queued.msg)) |value|
            .{ .fulfilled = value }
        else |err|
            .{ .broken = @errorName(err) };
        self.settleLocal(queued.vow, resolution) catch |err| {
            state.active_turns -= 1;
            self.finishQueueTurn(chunk);
            return err;
        };
        state.active_turns -= 1;
        self.finishQueueTurn(chunk);
    }

    fn beginSettle(self: *Vat) std.mem.Allocator {
        self.settle_depth += 1;
        return self.settle_arena.allocator();
    }

    fn endSettle(self: *Vat) void {
        self.settle_depth -= 1;
        if (self.settle_depth == 0) {
            _ = self.settle_arena.reset(.{ .retain_with_limit = steady_settle_arena_bytes });
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
    /// cloned into the settle arena shared with far settlement. Its depth guard
    /// lets a listener open a nested drive or far settle without freeing the
    /// outer listener's value.
    /// A broken resolution carries `@errorName`'s static string, which no
    /// reset can free.
    fn settleLocal(self: *Vat, vow_id: u64, resolution: Resolution) Error!void {
        // Local settlement only occurs inside a drive; hold that invariant
        // mechanically even though its clone now lives in the settle arena.
        std.debug.assert(self.drive_depth >= 1);
        // Remove before anything fallible: the turn ran, so a later `on` must
        // refuse even if cloning its result for an already-parked listener OOMs.
        std.debug.assert(self.pending_local_vows.remove(.{ .id = vow_id }));
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
                const arena = self.beginSettle();
                defer self.endSettle();
                const owned = try model.cloneArgument(arena, value);
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
};
