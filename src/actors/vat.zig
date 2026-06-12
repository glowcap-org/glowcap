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
//! handler has two honest choices, and the vat reclaims storage after either. It
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
    far: u64,
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
    /// an export position this vat answers for.
    NotLocal,
    /// A far `send` was made on a vat with no bound peer.
    NotConnected,
    /// `Vat.bindExport` was called for an export position already bound to an
    /// actor. Re-binding it would silently orphan the first actor, so it fails
    /// loudly. Which local object answers an export position is authority.
    AlreadyPublished,
    /// `Vat.on` was called for a promise that already holds a listener.
    /// Listeners are one-shot and a promise holds at most one, so replacing it
    /// would silently orphan the first — the same rule `bindExport` applies to
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
} || std.mem.Allocator.Error;

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
    self_ref: Ref,
    /// A per-turn allocator for the handler's reply and any scratch. The vat owns
    /// it and reclaims it when its next top-level turn begins, so a handler
    /// allocates from it freely and never frees the result. Nested near-calls and
    /// sends made inside one turn share it; it is reset only when an outermost turn
    /// begins.
    arena: std.mem.Allocator,

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
};

/// One single-threaded container of local objects — the Goblins-shaped layer
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
    far_listeners: std.AutoHashMapUnmanaged(u64, Listener) = .{},
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

    const Cell = struct {
        state: *anyopaque,
        handle: *const fn (state: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument,
        destroy: *const fn (state: *anyopaque, allocator: std.mem.Allocator) void,
    };

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
        while (it.next()) |cell| cell.destroy(cell.state, self.allocator);
        self.actors.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.listeners.deinit(self.allocator);
        self.far_listeners.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        self.turn_arena.deinit();
        self.queue_arena.deinit();
    }

    /// Spawn a local actor with `initial` state, returning a local `Ref`. No
    /// export position is minted: a partner cannot reach the actor until it is
    /// bound with `bindExport` (or spawned through the driver's exporting
    /// `spawn`), so this is the no-grant way to create one.
    pub fn spawn(self: *Vat, comptime Behavior: type, initial: Behavior) Error!Ref {
        const state = try self.allocator.create(Behavior);
        errdefer self.allocator.destroy(state);
        state.* = initial;

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
        };

        const id = self.next_actor;
        try self.actors.put(self.allocator, id, .{ .state = state, .handle = Glue.handle, .destroy = Glue.destroy });
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

    fn callLocal(self: *Vat, id: u64, msg: Message) anyerror!model.Argument {
        // Bound the near-call recursion before it can overflow the native stack:
        // each nested `$` deepens `turn_depth`, so refuse once it would exceed the
        // cap rather than crashing on a cyclic local graph.
        if (self.turn_depth >= max_near_call_depth) return Error.NearCallTooDeep;
        const cell = self.actors.get(id) orelse return Error.NoSuchActor;
        const arena = self.beginTurn();
        defer self.endTurn();
        var turn = Turn{ .vat = self, .self_ref = .{ .local = id }, .arena = arena };
        return cell.handle(cell.state, &turn, msg);
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
                const answer = peer.allocateAnswer();
                try self.farDeliver(far_ref, msg, answer);
                return .{ .far = answer };
            },
        }
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

    /// Encode a far `op:deliver` for `msg` to `far_ref`, requesting `answer`
    /// (null for a no-answer `tell`). Two named allocations live here, the
    /// one place the far-send path needs them. First, a scratch slice that
    /// splices the verb symbol ahead of the args, because the wire deliver
    /// carries `[verb, args…]` as one list while the actor API keeps the verb
    /// separate — freed immediately (the elements are borrowed, only the spine
    /// is owned). Second, the one boundary clone inside `peer.sendCopying`, which
    /// the outbound queue requires since `msg`'s args are borrowed from the
    /// caller. The splice cannot reuse the clone: `sendCopying` clones whatever
    /// list it is handed, and the verb must be in that list first.
    fn farDeliver(self: *Vat, far_ref: model.FarRef, msg: Message, answer: ?u64) Error!void {
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
            .target = .{ .far = far_ref },
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
    /// listener's break path synchronously, before this returns — a
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

    /// Run queued local eventual-sends to quiescence, settling each promise with
    /// the handler's value (or a break on error) and firing its listener. Turns
    /// queued by a turn run in the same drive (FIFO). The queued messages'
    /// clones live in the queue arena, which resets — capacity retained — only
    /// when the *outermost* drive has fully drained the queue, so a turn that
    /// queues more sends mid-drive never has its message freed under it.
    pub fn drive(self: *Vat) anyerror!void {
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
                const local_id = self.exports.get(export_position) orelse return false;
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
                        const id = rmd.position() orelse break :blk @as(?u64, null);
                        break :blk peer.session_state.answerForResolverImport(id);
                    }
                    break :blk @as(?u64, null);
                } else null;
                const reply = reply: {
                    // The depth and actor checks run before the turn opens,
                    // ordered exactly as `callLocal` orders them, so a refusal
                    // never resets the arena.
                    if (self.turn_depth >= max_near_call_depth) {
                        try self.resolveBreak(answer, @errorName(Error.NearCallTooDeep));
                        return true;
                    }
                    const cell = self.actors.get(local_id) orelse {
                        try self.resolveBreak(answer, @errorName(Error.NoSuchActor));
                        return true;
                    };
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
                    var turn = Turn{ .vat = self, .self_ref = .{ .local = local_id }, .arena = arena };
                    break :reply cell.handle(cell.state, &turn, messageFor(args)) catch |err| {
                        try self.resolveBreak(answer, @errorName(err));
                        return true;
                    };
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
    /// legitimately open a top-level turn (`near` or `drive`) while it runs —
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

    fn resolveFulfill(self: *Vat, answer: ?u64, reply: model.Argument) !void {
        const ans = answer orelse return;
        const peer = self.peer orelse return;
        try peer.sendCopying(.{ .resolve = .{ .answer = ans, .resolution = .{ .fulfill = reply } } });
    }

    fn resolveBreak(self: *Vat, answer: ?u64, message: []const u8) !void {
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
