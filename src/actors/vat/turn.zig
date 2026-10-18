//! The per-turn handler context: an actor's authority to spawn, near-call,
//! eventual-send, `become`, forward, and move replies out. The sibling frame
//! module opens the frame a `Turn` runs in.

const std = @import("std");
const engine = @import("engine");
const model = @import("model");

const boxed = @import("boxed.zig");
const serve = @import("serve.zig");
const forwarding = @import("forwarding.zig");
const frame = @import("frame.zig");
const vat_mod = @import("mod.zig");
const vows = @import("vows.zig");

const Message = vat_mod.Message;
const Delivery = vat_mod.Delivery;
const Ref = vat_mod.Ref;
const Vow = vat_mod.Vow;
const Error = vat_mod.Error;
const Vat = vat_mod.Vat;
const Port = vat_mod.Port;
const Listener = vat_mod.Listener;
const ListenerReservation = vat_mod.ListenerReservation;
const VowLocation = vat_mod.VowLocation;
const StateBox = boxed.StateBox;

/// The per-turn context handed to an actor's handler. It is the actor's authority
/// to spawn, near-call, and eventual-send, plus its own identity. An explicit
/// argument, never global: the Zig answer to Goblins's `current-syscaller`.
pub const Turn = struct {
    vat: *Vat,
    /// The causal queue this turn runs on, and the session Port whose
    /// authority caused it when one did. Near-calls and local sends inherit
    /// it, so an ingress cannot evade admission by bouncing through another
    /// actor.
    source: Source,
    /// The handled actor's own id.
    self_id: u64,
    /// A per-turn allocator for the handler's reply and any scratch. The vat owns
    /// it and reclaims it when its next top-level turn begins, so a handler
    /// allocates from it freely and never frees the result. Nested near-calls and
    /// sends made inside one turn share it. It is reset only when an outermost turn
    /// begins.
    arena: std.mem.Allocator,
    /// Adapter-local payload borrowed only during this queued handler. Null
    /// for model messages, including nested near calls.
    opaque_message: ?vat_mod.OpaqueMessage = null,
    /// The state box a `become` staged this turn, or null. Promoted when the
    /// turn frame returns successfully, released on a handler error.
    pending_become: ?*StateBox = null,
    /// Where this turn came from, the one axis `forward` dispatches on. No
    /// default: every constructor states the provenance, and the illegal
    /// combination (a near-call carrying a wire answer) is unrepresentable.
    origin: union(enum) {
        /// A synchronous near-call (`$`), whose caller consumes a value.
        local,
        /// A queued eventual call, whose local answer can be deferred.
        eventual: struct { answer: ?u64, outcome: *frame.EventualOutcome },
        /// An inbound wire deliver, carrying the answer this turn must settle,
        /// or null for a no-answer deliver (a wire `tell`). `forward` defers
        /// the answer onto the forwarded send's vow.
        served: ?engine.AnswerTarget,
    },
    /// Set by `forward`: this turn handed its answer off to a forwarded send's
    /// vow, so `serve` must not resolve it from the handler's return value.
    forwarded: bool = false,
    /// Index into `Vat.moved_replies` where this turn's `moveOut` transfers
    /// began (set on the turn's first move, null when nothing was moved). The
    /// vat already holds the bytes. This field only lets `callLocal` recognize
    /// a returned reply as one of the allocations this turn moved, any of
    /// them, not just the last, so a vat-owned reply outlives a same-turn
    /// `become` with no sever-copy.
    moves_begin: ?usize = null,

    /// Where a turn's causal queue is.
    pub const Source = union(enum) {
        /// A pure-local turn on this queue.
        ingress: vat_mod.IngressId,
        /// A turn a session Port caused, on that Port's queue.
        port: *Port,

        pub fn ingressId(self: Source) vat_mod.IngressId {
            return switch (self) {
                .ingress => |id| id,
                .port => |via| via.ingress,
            };
        }
    };

    /// The handled actor's own reference, for replying with itself or handing
    /// itself out as a callback.
    pub fn me(self: *const Turn) Ref {
        return .{ .local = self.self_id };
    }
    /// The session Port whose authority caused this turn, or null for a
    /// pure-local turn.
    pub fn port(self: *const Turn) ?*Port {
        return switch (self.source) {
            .port => |via| via,
            .ingress => null,
        };
    }
    /// The causal queue this turn runs on.
    pub fn ingress(self: *const Turn) vat_mod.IngressId {
        return self.source.ingressId();
    }
    /// Spawn a new actor in this vat (see `Vat.spawn`).
    pub fn spawn(self: *Turn, comptime Behavior: type, initial: Behavior) Error!Ref {
        return self.vat.spawn(Behavior, initial);
    }
    /// Synchronously call another local actor and return its reply, the `$`
    /// of this layer (see `Vat.near`). Keeps `anyerror`: this is
    /// the application handler boundary, and a refused handler reconstructs
    /// its own error by value.
    pub fn near(self: *Turn, target: Ref, msg: Message) anyerror!model.Argument {
        return self.vat.nearDelivery(self.source, target, msg.delivery());
    }
    /// Eventual-send to a local or far reference, returning the reply
    /// `Vow`, the `<-` of this layer. Pure-local turns enter through
    /// `Vat.send`. Turns with a session projection enter through `Port.send`.
    pub fn send(self: *Turn, target: Ref, msg: Message) Error!Vow {
        return switch (self.source) {
            .port => |via| via.send(self.vat, target, msg),
            .ingress => |id| self.vat.sendFromIngress(id, target, msg),
        };
    }
    /// Fire-and-forget eventual-send while preserving this turn's Port and
    /// causal ingress. A handler must use this rather than reaching through
    /// `turn.vat.tell`, which would reclassify the work as pure-local.
    pub fn tell(self: *Turn, target: Ref, msg: Message) Error!void {
        return switch (self.source) {
            .port => |via| via.tell(self.vat, target, msg),
            .ingress => |id| self.vat.tellFromIngress(id, target, msg),
        };
    }
    /// `send` for a delivery as a handler holds it. A far delivery is the
    /// Port's to send as it is (`Port.sendDelivery`), and a local one
    /// becomes a message in this turn's arena.
    pub fn sendDelivery(self: *Turn, target: Ref, delivery: Delivery) Error!Vow {
        if (target == .far) if (self.port()) |via| return via.sendDelivery(self.vat, target, delivery);
        return self.send(target, try self.messageOf(delivery));
    }
    /// `tell` for a delivery as a handler holds it, routed as `sendDelivery`.
    pub fn tellDelivery(self: *Turn, target: Ref, delivery: Delivery) Error!void {
        if (target == .far) if (self.port()) |via| return via.tellDelivery(self.vat, target, delivery);
        return self.tell(target, try self.messageOf(delivery));
    }
    fn messageOf(self: *Turn, delivery: Delivery) Error!Message {
        return delivery.toMessage(self.arena) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.MalformedView => Error.MalformedView,
        };
    }
    /// Functional "become" for a persistent actor (mirrors Goblins `bcom`): stage
    /// `next` as this actor's state. The new value is installed when this turn
    /// frame returns successfully and discarded if the handler errors, so a failed
    /// turn leaves the actor unchanged. If the frame is a reentrant near-call into
    /// an actor already running an outer frame, the install waits for that outer
    /// frame, so the box the outer frame holds as `self` is never freed under it.
    /// A persistent actor never mutates its `self`. It calls `become` instead,
    /// which is why a snapshot can share its state with no copy-on-write. Calling
    /// it twice in one turn keeps the last value.
    /// `next` is consumed on every outcome: on failure its resources are
    /// reclaimed through the state's `deinit`, so the caller never frees it.
    pub fn become(self: *Turn, comptime Behavior: type, next: Behavior) Error!void {
        return boxed.stageBecome(self.vat, self, Behavior, next);
    }

    /// Move an owned byte field out of the actor's state into the reply: hand
    /// the bytes to the vat, clear the field so the actor's `deinit` no longer
    /// frees them, and return them as a `bytes` argument. A transfer, not a
    /// borrow, the vat frees the bytes when its next outermost turn begins,
    /// the same lifetime a borrowed reply has, so handing off a large buffer
    /// is O(1) where copying it onto the turn arena is O(len), and the reply
    /// outlives a same-turn `become` with no sever-copy.
    ///
    /// Clearing the field *is* the move: no second owner survives, so the vat's
    /// free can never race the state's `deinit`. That makes the two obligations
    /// structural rather than remembered, the field must be a mutable slice
    /// the actor's state owns on the vat's allocator (the same allocator its
    /// `deinit` would free it with). A `*const` persistent handler cannot take
    /// `&self.field` mutably, so it cannot call this. It severs through the
    /// ordinary borrowed-reply path instead.
    ///
    /// The parameter is a mutable pointer for a reason, and that reason is why
    /// no wrapper type is owed. A borrow or a copy would take the bytes by
    /// value. Only a transfer asks for `&self.field`, so the pointer already
    /// says the field is being given away. Clearing it to empty makes that
    /// structural: a handler that reuses the field reads empty bytes, never
    /// freed storage. A newtype guarding against silent reuse would tax every
    /// actor's state definition for a mistake the sever already turns into a
    /// harmless empty read, so `moveOut` stays a function that takes the field
    /// and nulls it. The cleared-field contract is pinned by the "leaves the
    /// field cleared" test.
    ///
    /// On out-of-memory the field is left exactly as it was. A handler error
    /// after a successful move does not restore the field, mutable-actor
    /// state changes never roll back, and the moved bytes are still freed by
    /// the vat, so nothing leaks.
    ///
    /// Eventual-path accounting: on a listened `send` then `drive`
    /// path the moved reply is still cloned once for the listener,
    /// necessarily, because a listener-opened top-level turn would drain the
    /// moved bytes mid-call, so the full O(1) win is on `near` and `tell`. A
    /// listened send saves only the become sever-copy.
    pub fn moveOut(self: *Turn, field: *[]u8) Error!model.Argument {
        return .{ .bytes = try self.moveOutSlice(field) };
    }

    /// `moveOut`'s string arm: the same O(1) transfer, returned as a `string`
    /// argument for text the actor owns as a byte buffer. One mechanism, two
    /// wire arms. Every `moveOut` obligation and lifetime applies unchanged.
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
    /// behavior that returns `(apply <- target args)`. Glowcap's handler returns
    /// a concrete value, so `forward` instead defers the inbound answer and
    /// settles it when the forwarded send settles, local or far. `target` may be
    /// local or far: a far forward is what lets a holder hand out an attenuated
    /// or revocable view of a capability it imported over the wire.
    ///
    /// What comes back depends on the turn's `origin`: a `.local` frame gets
    /// the target's real value (the vat consumes the return directly, so the
    /// forward runs as a synchronous near-call). An eventual or served turn gets a `void`
    /// placeholder the vat ignores, with the real answer riding the forwarded
    /// vow, or, for a no-answer `tell`, a fire-and-forget forward.
    /// Forwarding does not preserve promise pipelining *through* the proxy: a
    /// partner pipelining on the proxy's answer queues on this side until the
    /// forwarded send settles (ADR-0064). Keeps `anyerror`: the
    /// local arm re-enters the near-call handler boundary.
    /// Reserve the listener table a not-yet-committed send from this turn
    /// will use: the Port's for a Port-caused turn, else the vat's local
    /// table, where only a local vow can be observed.
    pub fn reserveListener(self: *Turn, location: VowLocation) Error!ListenerReservation {
        return switch (self.source) {
            .port => |via| via.reserveListener(self.vat, location),
            .ingress => {
                if (location != .local) return error.NotConnected;
                try vows.reserveLocalListener(self.vat);
                return .{ .location = .local };
            },
        };
    }

    /// Install `listener` on the fresh `vow` into capacity `reserveListener`
    /// took.
    pub fn onReserved(self: *Turn, reservation: ListenerReservation, vow: Vow, listener: Listener) void {
        switch (self.source) {
            .port => |via| via.onReserved(self.vat, reservation, vow, listener),
            .ingress => {
                std.debug.assert(vow == .local and reservation.location == .local);
                vows.onReservedLocal(self.vat, vow.local, listener);
            },
        }
    }

    /// Observe an existing vow from this turn's source (`Port.on` or
    /// `Vat.on`).
    pub fn observe(self: *Turn, vow: Vow, listener: Listener) Error!void {
        return switch (self.source) {
            .port => |via| via.on(self.vat, vow, listener),
            .ingress => self.vat.on(vow, listener),
        };
    }

    /// Remove and return `vow`'s pending listener without settling it.
    pub fn unobserve(self: *Turn, vow: Vow) ?Listener {
        return switch (self.source) {
            .port => |via| via.takeListener(self.vat, vow),
            .ingress => self.vat.takeListener(vow),
        };
    }

    pub fn forward(self: *Turn, target: Ref, msg: Delivery) anyerror!model.Argument {
        return forwarding.forwardTurn(self.vat, self, target, msg);
    }

    /// Forward an adapter-owned local delivery on the same answer chain.
    pub fn forwardOpaque(self: *Turn, target: Ref, msg: vat_mod.OpaqueMessage) !void {
        return forwarding.forwardOpaque(self.vat, self, target, msg);
    }

    pub const AnswerTransfer = forwarding.ForwardContext;

    /// Adapter-owned completion carries the captured answer in its own owner.
    /// Prepare before effects, commit after admission, complete exactly once.
    pub fn prepareAnswerTransfer(self: *Turn) !?AnswerTransfer {
        return AnswerTransfer.prepare(self);
    }

    /// Commit an adapter's admitted fire-and-forget forward without an answer.
    pub fn forwardNoAnswer(self: *Turn) void {
        forwarding.commitNoAnswer(self);
    }

    /// Defer this turn's answer onto `vow` (ADR-0102): the answer settles
    /// when the vow does. The behavior-side half of off-turn settlement, a
    /// handler mints a resolver pair (`Vat.spawnVow`), forwards its answer
    /// here, hands the resolver to whatever completes the work, and returns
    /// normally. The eventual `Vat.fulfillVow` / `Vat.breakVow` settles the
    /// answer as its own top-level event. Eventual and served turns can defer.
    /// Synchronous near calls refuse (`NotLocal`). A no-answer tell has nothing
    /// to defer and is marked forwarded.
    pub fn forwardVow(self: *Turn, vow: Vow) !void {
        return forwarding.forwardTurnVow(self.vat, self, vow);
    }

    /// Reserve the fallible half of a vow deferral without publishing the vow.
    /// Host adapters use this to make resolver mint + turn deferral one atomic
    /// operation across their own row tables and the Vat.
    pub fn reserveForwardVow(self: *Turn, location: vat_mod.VowLocation) !forwarding.ForwardReservation {
        return forwarding.reserveForward(self.vat, self, location);
    }

    /// Release unpublished forward capacity when a later reservation refuses.
    pub fn cancelForwardVow(self: *Turn, reservation: forwarding.ForwardReservation) void {
        forwarding.cancelForward(self.vat, reservation);
    }

    /// Commit a fresh vow into a reservation returned by `reserveForwardVow`.
    /// No allocation or refusal remains after the reservation succeeds.
    pub fn forwardReservedVow(self: *Turn, reservation: forwarding.ForwardReservation, vow: Vow) void {
        forwarding.commitForward(self.vat, self, reservation, vow);
    }

    /// Break this turn's own answer with `message`, the eventual-turn spelling
    /// of a handler failure that must carry its diagnostic. A Zig handler
    /// breaks by returning an error, whose `@errorName` becomes the reason. A
    /// hosted behavior's return code carries no message at all, so this verb
    /// is how a caretaker's "Revoked" or an attenuator's "Attenuated" crosses
    /// the boundary intact. A wire answer breaks now. A queued local answer
    /// breaks after the handler unwinds. A tell has no answer to break. The
    /// turn is marked forwarded so the handler's
    /// eventual return value resolves nothing, the handler still returns
    /// normally after calling this. A second call in the same turn is a no-op:
    /// answer already has its outcome. A synchronous `.local` frame's
    /// caller consumes the return value directly, so a break has
    /// nowhere to land and the handler raises instead (`NotLocal`).
    pub fn breakWith(self: *Turn, message: []const u8) !void {
        switch (self.origin) {
            .served => |answer| {
                if (self.forwarded) return;
                try serve.resolveBreak(self.source.port, answer, message);
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
            .local => return error.NotLocal,
        }
    }
};
