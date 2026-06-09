//! A vat: a turn loop over a heap of actors, local and remote alike.
//!
//! This is pancake's Goblins-shaped actor model, expressed in native Zig, and it
//! is the seam where the actor architecture meets the OCapN engine. A vat owns a
//! set of local actors (an id → behavior+state map) and a queue of pending
//! eventual-sends, and — when bound to a peer — routes sends to *remote* objects
//! over the wire. You drive it; it owns no I/O and no scheduler thread, so it
//! stays in the sync, no-I/O core — the same posture as the engine it rides on.
//!
//! An actor is any type with `pub fn handle(self: *@This(), turn: *Turn, msg:
//! Message) !model.Argument` (and, optionally, `pub fn deinit(self, allocator)`).
//! Its mutable `self` *is* its state: where Goblins returns a fresh behavior via
//! `bcom`, a Zig actor assigns its own fields — same "become", the way Zig gives
//! you mutable state.
//!
//! Ownership at the handler boundary is *turn-scoped*. The `Message` a handler
//! receives borrows its arguments for the duration of the turn. For its reply a
//! handler has two honest choices, and the vat reclaims storage after either. It
//! can return a value owned by its own `self` or aliased from the message, which
//! allocates nothing. Or it can allocate the reply — and any scratch — from
//! `turn.arena`, the per-turn allocator the vat hands every handler. The vat owns
//! that arena and resets it when its next top-level turn begins, so a handler
//! never frees its own reply and never leaks one. The reply is therefore valid
//! until the vat's next top-level turn: within that window the vat hands it to the
//! local promise's listener or clones it onto the wire (the one clone in
//! `peer.sendCopying`). To keep a value beyond your turn, store it in `self` or
//! copy it; never return storage that ends before the turn does. A `Resolution`
//! delivered to a listener follows the same rule — it is valid for that listener
//! call only, and a listener that keeps it copies first.
//!
//! Two verbs, matching Goblins:
//!   * [`Vat.call`] — the synchronous near-call (`$`): run an actor's handler now
//!     and return its value. Legal only for a *local* ref (same vat), exactly as
//!     Goblins forbids `$` to a far ref.
//!   * [`Vat.send`] — the eventual send (`<-`): location-transparent. To a local
//!     ref it queues a turn; to a far ref it sends an `op:deliver` over the bound
//!     peer. Either way it returns a [`Promise`] you observe with [`Vat.on`].
//!
//! The unified [`Ref`] (local or far) and [`Promise`] (local or wire-answer) are
//! the seam: an application sends to a ref without caring where it lives, and the
//! vat routes. The engine stays codec + authority only; the vat is the driver
//! above it (it imports the engine, never the reverse).

const std = @import("std");
const model = @import("../model/mod.zig");
const engine = @import("../engine/mod.zig");

/// A reference the vat can eventual-send to, wherever the object lives.
pub const Ref = union(enum) {
    /// An actor in this vat — `call`/`send` run its turns here.
    local: u64,
    /// A partner-hosted object the bound peer holds as an import — `send` routes
    /// to it as an `op:deliver`; `call` (near) is illegal.
    far: model.FarRef,
};

/// A handle to the eventual result of a [`Vat.send`].
pub const Promise = union(enum) {
    /// Result of a local send; settled by [`Vat.drive`].
    local: u64,
    /// Result of a far send; the outbound answer position the partner resolves.
    far: u64,
};

/// A message to an actor: a verb (method selector) and its arguments. The verb
/// and args are borrowed for the duration of the turn — the vat does not own or
/// free them, and a handler that keeps a value past its turn copies it first.
pub const Message = struct {
    verb: []const u8,
    args: []const model.Argument = &.{},

    pub fn arg(self: Message, i: usize) model.Argument {
        return self.args[i];
    }
};

/// How a promise settled. The carried value (`fulfilled` argument or `broken`
/// message) is borrowed for the duration of the listener call only — a listener
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
    /// A near-call (`call` / `$`) was made to a far ref; only `send` reaches one.
    NotNearCallable,
    /// A far `send` was made on a vat with no bound peer.
    NotConnected,
    /// [`Vat.publish`] was called for an export position already bound to an
    /// actor. Re-binding it would silently orphan the first actor, so it fails
    /// loud — which local object answers an export position is authority.
    AlreadyPublished,
} || std.mem.Allocator.Error;

/// The per-turn context handed to an actor's handler — its ambient authority to
/// spawn, near-call, and eventual-send, plus its own identity. An explicit
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

    pub fn me(self: *const Turn) Ref {
        return self.self_ref;
    }
    pub fn spawn(self: *Turn, comptime Behavior: type, initial: Behavior) Error!Ref {
        return self.vat.spawn(Behavior, initial);
    }
    pub fn call(self: *Turn, target: Ref, msg: Message) anyerror!model.Argument {
        return self.vat.call(target, msg);
    }
    pub fn send(self: *Turn, target: Ref, msg: Message) Error!Promise {
        return self.vat.send(target, msg);
    }
};

pub const Vat = struct {
    allocator: std.mem.Allocator,
    /// The peer this vat rides on, or null for a pure-local vat. Far sends and
    /// hosting require it; the vat still owns no I/O — it only enqueues onto the
    /// peer's outbound queue and reads its events.
    peer: ?*engine.Peer = null,
    actors: std.AutoHashMapUnmanaged(u64, Cell) = .{},
    queue: std.ArrayList(Queued) = .empty,
    listeners: std.AutoHashMapUnmanaged(u64, Listener) = .{},
    /// Outbound answer position → listener for a far send's promise.
    far_listeners: std.AutoHashMapUnmanaged(u64, Listener) = .{},
    /// Export position → local actor id, for actors published on the peer.
    exports: std.AutoHashMapUnmanaged(u64, u64) = .{},
    /// Per-turn scratch the vat hands each handler as `turn.arena`. A handler's
    /// reply and scratch live here; the vat reclaims the whole arena when its next
    /// outermost turn begins (when `turn_depth` returns to 0 and rises again), so a
    /// reply stays valid until then and no handler frees or leaks its own reply.
    turn_arena: std.heap.ArenaAllocator,
    /// Nesting depth of in-flight turns. The turn arena resets only at depth 0, so a
    /// near-call or send made inside a turn shares that turn's scratch rather than
    /// pulling it out from under the call in flight.
    turn_depth: u32 = 0,
    next_actor: u64 = 1,
    next_promise: u64 = 1,

    const Cell = struct {
        state: *anyopaque,
        handle: *const fn (state: *anyopaque, turn: *Turn, msg: Message) anyerror!model.Argument,
        destroy: *const fn (state: *anyopaque, allocator: std.mem.Allocator) void,
    };

    const Queued = struct { target: u64, msg: Message, promise: u64 };

    /// A pure-local vat (no wire). `call`/`send`/`drive` over local actors only.
    pub fn init(allocator: std.mem.Allocator) Vat {
        return .{ .allocator = allocator, .turn_arena = std.heap.ArenaAllocator.init(allocator) };
    }

    /// A vat bound to `peer`: far sends route to it, and `publish` exports actors
    /// so inbound deliveries (via [`serve`]) run their turns.
    pub fn initOver(allocator: std.mem.Allocator, peer: *engine.Peer) Vat {
        return .{ .allocator = allocator, .peer = peer, .turn_arena = std.heap.ArenaAllocator.init(allocator) };
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
    }

    /// Spawn a local actor with `initial` state, returning a local [`Ref`].
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
    /// value. Legal only for a local ref — a far ref must be reached with `send`.
    /// The returned `Argument` is borrowed from the actor's state or the message
    /// (see the module header) and is valid only as long as both are; a caller
    /// that keeps it copies first.
    pub fn call(self: *Vat, target: Ref, msg: Message) anyerror!model.Argument {
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
        const cell = self.actors.get(id) orelse return Error.NoSuchActor;
        const arena = self.beginTurn();
        defer self.endTurn();
        var turn = Turn{ .vat = self, .self_ref = .{ .local = id }, .arena = arena };
        return cell.handle(cell.state, &turn, msg);
    }

    /// The eventual send (`<-`): location-transparent. A local target queues a
    /// turn for [`drive`]; a far target sends an `op:deliver` over the bound peer
    /// (a leading symbol carries the verb, matching Goblins's `($ obj 'method …)`).
    /// Returns a [`Promise`] for the result. Message args are borrowed until the
    /// send is processed (until `drive` for local; until encode for far).
    pub fn send(self: *Vat, target: Ref, msg: Message) Error!Promise {
        switch (target) {
            .local => |id| {
                const promise = self.next_promise;
                try self.queue.append(self.allocator, .{ .target = id, .msg = msg, .promise = promise });
                self.next_promise += 1;
                return .{ .local = promise };
            },
            .far => |far_ref| {
                const peer = self.peer orelse return Error.NotConnected;
                const answer = peer.allocateAnswer();
                const has_verb = msg.verb.len > 0;
                // Two named allocations on the far-send path. First, a scratch
                // slice that splices the verb symbol ahead of the args, because the
                // wire deliver carries `[verb, args…]` as one list while the actor
                // API keeps the verb separate — freed immediately below (the
                // elements are borrowed, only the spine is owned). Second, the one
                // boundary clone inside `peer.sendCopying`, which the outbound queue
                // requires since `msg`'s args are borrowed from the caller. The
                // splice cannot reuse the clone: `sendCopying` clones whatever list
                // it is handed, and the verb must be in that list first.
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
                } }) catch return Error.OutOfMemory;
                return .{ .far = answer };
            },
        }
    }

    /// The fire-and-forget eventual-send (Goblins `<-np`): like [`send`], but it
    /// requests no answer, so the partner's actor runs and sends no reply. A far
    /// `sendOnly` puts one `op:deliver` with no answer on the wire — the right
    /// shape for a notification or broadcast, which would otherwise pay for a
    /// reply nobody reads. A local `sendOnly` queues a turn whose result is
    /// discarded. Returns nothing: there is no promise to observe.
    pub fn sendOnly(self: *Vat, target: Ref, msg: Message) Error!void {
        switch (target) {
            .local => |id| {
                // Queue a turn like `send`, but with no observable promise; the
                // promise id keeps the queue entry uniform and `drive` settles it
                // into no listener.
                const promise = self.next_promise;
                try self.queue.append(self.allocator, .{ .target = id, .msg = msg, .promise = promise });
                self.next_promise += 1;
            },
            .far => |far_ref| {
                const peer = self.peer orelse return Error.NotConnected;
                const has_verb = msg.verb.len > 0;
                // Same verb-splice as `send` (see there); the one difference is
                // `.answer = null`, so no answer position is allocated and the
                // partner returns nothing.
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
                    .answer = null,
                } }) catch return Error.OutOfMemory;
            },
        }
    }

    /// Register a one-shot listener for `promise`. A local promise fires during
    /// [`drive`]; a far promise fires when the partner's resolution arrives and is
    /// dispatched by [`serve`].
    pub fn on(self: *Vat, promise: Promise, listener: Listener) Error!void {
        switch (promise) {
            .local => |id| try self.listeners.put(self.allocator, id, listener),
            .far => |answer| try self.far_listeners.put(self.allocator, answer, listener),
        }
    }

    /// Break every outstanding far promise with `message`, firing each listener's
    /// break path. A far promise settles only when the partner's resolution
    /// arrives over the wire, so once the connection is gone those resolutions can
    /// never come. A driver calls this on disconnect, so an awaiting [`on`]
    /// listener settles broken instead of waiting forever. `message` is borrowed
    /// for the duration of the calls, so a static string is the norm. Local
    /// promises are untouched: they settle synchronously in [`drive`] and never
    /// wait on the wire.
    pub fn breakFarVows(self: *Vat, message: []const u8) void {
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

    /// Publish a local actor at export position `id` so a partner's deliveries to
    /// it run the actor (dispatched by [`serve`]). Requires a bound peer.
    pub fn publish(self: *Vat, actor: Ref, id: u64) !void {
        const local_id = switch (actor) {
            .local => |a| a,
            .far => return Error.NotNearCallable,
        };
        const peer = self.peer orelse return Error.NotConnected;
        // Reject a collision before touching the peer: the export → actor map is
        // authority (it decides which local object a partner reaches), so a second
        // bind to the same position fails loud rather than orphaning the first.
        const gop = try self.exports.getOrPut(self.allocator, id);
        if (gop.found_existing) return Error.AlreadyPublished;
        // getOrPut inserted the key with an undefined value; if registering the
        // export fails, drop the half-inserted entry so the map never holds a
        // position the peer doesn't actually export.
        errdefer _ = self.exports.remove(id);
        try peer.exportObject(id);
        gop.value_ptr.* = local_id;
    }

    /// Run queued local eventual-sends to quiescence, settling each promise with
    /// the handler's value (or a break on error) and firing its listener. Turns
    /// queued by a turn run in the same drive (FIFO).
    pub fn drive(self: *Vat) anyerror!void {
        var index: usize = 0;
        while (index < self.queue.items.len) {
            const queued = self.queue.items[index];
            index += 1;
            const resolution: Resolution = if (self.callLocal(queued.target, queued.msg)) |value|
                .{ .fulfilled = value }
            else |err|
                .{ .broken = @errorName(err) };
            self.settleLocal(queued.promise, resolution);
        }
        self.queue.clearRetainingCapacity();
    }

    /// Dispatch one inbound peer event: a deliver to a published actor runs its
    /// turn and resolves the answer; a resolve for a far promise fires its
    /// listener. Returns whether the event belonged to this vat; if it did not,
    /// the caller handles it. The application polls the peer and hands events here.
    pub fn serve(self: *Vat, event: *engine.Event) !bool {
        const body = event.view() catch return false;
        switch (body) {
            .deliver => |deliver| {
                const export_id = switch (deliver.target) {
                    .near => |near| near.export_id,
                    else => return false,
                };
                const local_id = self.exports.get(export_id) orelse return false;
                // V1.0: when the deliver has no wire answer but carries a
                // resolve_me_desc, the engine installed a virtual answer for
                // the resolver. Look it up so the resolve reaches the partner.
                const answer = deliver.answer orelse if (self.peer) |peer| blk: {
                    if (deliver.resolve_me_desc) |rmd| {
                        // The resolve-me-desc may arrive as `.far` (original
                        // inbound from the wire) or `.near` (a synthesized
                        // pipelined-drain event that round-tripped through
                        // encode+decode, flipping the perspective). Accept both.
                        const id = switch (rmd) {
                            .far => |far| far.import_id,
                            .near => |near| near.export_id,
                            else => break :blk @as(?u64, null),
                        };
                        break :blk peer.session_state.answerForResolverImport(id);
                    }
                    break :blk @as(?u64, null);
                } else null;
                const args = try deliver.args.toOwnedSlice(self.allocator);
                defer model.freeArgumentSlice(self.allocator, args);
                const reply = self.callLocal(local_id, messageFor(args)) catch |err| {
                    try self.resolveBreak(answer, @errorName(err));
                    return true;
                };
                try self.resolveFulfill(answer, reply);
                return true;
            },
            .resolve => |resolve| {
                const entry = self.far_listeners.fetchRemove(resolve.answer) orelse return false;
                switch (resolve.resolution) {
                    .fulfill => |value| {
                        const owned = try value.toOwned(self.allocator);
                        defer model.freeArgument(self.allocator, owned);
                        entry.value.func(entry.value.ctx, .{ .fulfilled = owned });
                    },
                    .break_ => |reason| entry.value.func(entry.value.ctx, .{ .broken = reason.message }),
                }
                return true;
            },
            else => return false,
        }
    }

    fn settleLocal(self: *Vat, promise_id: u64, resolution: Resolution) void {
        if (self.listeners.fetchRemove(promise_id)) |entry| {
            entry.value.func(entry.value.ctx, resolution);
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
        try peer.sendCopying(.{ .resolve = .{ .answer = ans, .resolution = .{ .break_ = .{ .message = message } } } });
    }
};

/// Split an inbound deliver's args into a method verb and its arguments: a
/// leading symbol is the verb, the rest are its arguments. This is the inverse of
/// what [`Vat.send`] does on the way out (it prepends the verb as a leading
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
