//! The outbound enqueue/encode path: pending-send carriers, store-borrow fires,
//! and the encode step that drains them onto `outbound`.
//!
//! Free functions over `*Peer`, the same shape `inbound.zig` and `pipeline.zig`
//! use. The public `Peer.send` / `takeOutbound` surface stays on `Peer` in
//! `mod.zig` and calls in here.

const std = @import("std");

const codec = @import("codec");
const model = @import("model");
const session = @import("session");

const engine = @import("mod.zig");
const Peer = engine.Peer;

const abort_projection = @import("abort_projection.zig");
const lower = @import("lower.zig");
const pipeline = @import("pipeline.zig");
const v1_0 = @import("v1_0.zig");

const freeMessage = model.freeMessage;

/// A fire payload that lives in a store: an inbound answer's stored
/// resolution, or a handoff-imported third-party promise's stored resolution
/// (ADR-0009). The two share the promise cell shape — `{ row_id, resolution,
/// listeners }` — keyed on distinct wire position spaces, so one
/// `resolveFireStore` lookup serves both, and each arm carries its row's
/// identity stamp because only a store row has one. This is its own type so
/// the store lookup's parameter admits exactly the targets it can answer.
pub const StoreTarget = union(enum) {
    answer: struct { position: model.AnswerPosition, row_id: u64 },
    import: struct { position: model.ImportPosition, row_id: u64 },
};

/// Which payload a listener fire borrows at encode: a store-backed resolution
/// (`StoreTarget` above), or a live object export's POD `fulfill(near)` — no
/// store row, the export position in the carrier is the payload, and export
/// positions are never reused so no stamp rides beside it.
pub const FireTarget = union(enum) {
    store: StoreTarget,
    near_object: model.ExportPosition,
};

const NextAnswered = struct {
    operation: model.Message,
    listener: model.Message,
};

/// One slot in the outbound queue. Most kinds queue a fully-built `message` the
/// queue owns until `step` encodes it. A sent `op:resolve` is the exception: its
/// resolution lives in the answer store (it moved there at record time), so the
/// queue holds only `settled_answer` — the position of the inbound answer it
/// settles, plus that row's identity stamp — and `step` reads the resolution
/// back from the store to encode.
/// That single store ownership is the point: the resolution is not copied into a
/// frame here and the store there. An inbound `op:gc-answers` that drops the row
/// between record and emit leaves nothing to encode, and a partner that reuses
/// the freed position for a fresh answer leaves a row whose identity stamp no
/// longer matches — either way the carrier's `row_id` check emits nothing wrong
/// (a self-contained frame copy would dangle or ship the reused payload on
/// exactly those sequences; this stamped carrier cannot).
///
/// A listener fire rides the same store-borrow pattern: when a promise with N
/// listeners resolves, each fire queues a POD `listener_fire` carrier instead
/// of N payload clones, and `step` borrows the stored resolution back to encode
/// (`pipeline.borrowedListenerFire`). A row dropped (or replaced by a different
/// row instance at the same position — the carrier carries the row's identity
/// stamp) between queue and encode leaves the fire moot, the same semantics
/// `settled_answer` ships. A surviving row's stored payload cannot change under
/// a queued carrier: an answer resolves once (`validateInboundResolve` /
/// `applySentResolve`) and a relayed resolution records once
/// (`recordRelayedResolution` refuses a second relay), so a matching identity
/// stamp proves the payload too.
pub const Outbound = union(enum) {
    message: model.Message,
    /// A next-profile answered operation and the mandatory listener that must
    /// immediately follow it. `step` encodes both and reserves both outbound
    /// slots before publishing either frame, so an internal allocation failure
    /// cannot expose the operation without its listener.
    next_answered: NextAnswered,
    /// A sent `op:resolve` whose resolution lives in the inbound answer store
    /// (it moved there at record time). Carries the answer position *and* the
    /// store row's identity stamp, exactly as `listener_fire` does over the
    /// same store: answer positions are partner-named, so a released one can be
    /// reused by a fresh answer with a different resolution before this carrier
    /// is encoded. At encode `step` drops the resolve when the row is gone
    /// (`peekResolution` null) *or* its `row_id` no longer matches (a reused
    /// position now holding a different answer), so the reused row's payload is
    /// never emitted under this carrier.
    settled_answer: struct {
        position: model.AnswerPosition,
        row_id: u64,
    },
    /// One `op:listen` fire. The `target` names which payload `step` borrows at
    /// encode: an inbound answer (`peekResolution`), a handoff-imported
    /// third-party promise (ADR-0009), or a live object export's POD
    /// `fulfill(near)` (`FireTarget.near_object`). Store-backed targets carry
    /// the store row's identity stamp inside their arm, stamped at queue time;
    /// `near_object` encodes from the export position when the row is still
    /// live. Queue-time accounting already ran (`pipeline.enqueueFire` /
    /// `enqueueNearObjectFire`). At encode `step` drops the fire when the row
    /// is gone or its `row_id` changed (answer positions are partner-named;
    /// imported rows can be torn down and re-registered). Emitting the reused
    /// row's payload under this fire's accounting would drift the wire-delta
    /// retains.
    listener_fire: struct {
        listener_position: u64,
        target: FireTarget,
    },

    pub fn deinit(self: Outbound, allocator: std.mem.Allocator) void {
        switch (self) {
            // The store owns a settled answer's / fire's resolution and frees
            // it at row GC, overwrite, or session teardown; the carriers own
            // nothing.
            .settled_answer, .listener_fire => {},
            .next_answered => |pair| {
                freeMessage(allocator, pair.operation);
                freeMessage(allocator, pair.listener);
            },
            .message => |message| freeMessage(allocator, message),
        }
    }
};

/// Record and enqueue one *flat* (no-decomposition) `message` for outbound
/// encode, taking ownership of its heap. The shared tail of `send` and the
/// decomposed-chain links — kept separate so the chain links bypass the
/// (already-checked) multi-hop guard, breaking the `send` recursion cycle.
pub fn enqueueRecorded(self: *Peer, message_in: model.Message) !void {
    // Lower any node-local foreign-import token this message carries to its
    // wire reference, in place, before it is recorded or encoded (ADR-0069).
    // This is the single chokepoint every flat outbound message funnels
    // through — the direct send, each decomposed pipeline link, a prepared
    // fetch — so a token cannot leak onto the wire in any position. A
    // `TokenNotLiftable` aborts the send with the message still owned here.
    var message = message_in;
    if (self.node_services) |services| {
        if (services.lowering_active.*) lower.lowerMessage(services, &message) catch |err| {
            freeMessage(self.allocator, message);
            return err;
        };
    }

    self.session_state.rewriteShortenedMessage(&message);
    if (message == .gc_export) {
        self.session_state.expandShorteningGcExportReleases(self.allocator, &message.gc_export) catch |err| {
            freeMessage(self.allocator, message);
            return err;
        };
    }

    if (self.session_state.captp_version == .next) {
        if (answerProducedBy(message)) |answer| {
            return enqueueNextAnsweredOperation(self, message, answer);
        }
    }

    // A sent `op:resolve` moves its resolution into the answer store at
    // record time (`recordSend` consumes it), so the queue carries only the
    // settled answer position. Reserve the carrier slot *before* recording:
    // the resolution transfer is then committed by an infallible push, never
    // by an undo — a record that succeeded but failed to enqueue would settle
    // the answer with no frame to carry it to the partner.
    if (message == .resolve) {
        const answer = message.resolve.answer;
        // Reserve before `recordSend` consumes the resolution. A failure here
        // is the one spot on this fast path that leaves `message` unrecorded
        // and unqueued, so free it — `recordSend` owns it from the next line
        // on (it frees on refusal), and `pushAssumeCapacity` is infallible.
        self.pending_send.ensureUnusedCapacityForOne(self.allocator) catch |err| {
            freeMessage(self.allocator, message);
            return err;
        };
        try self.session_state.recordSend(message);
        // Stamp the carrier with the answer row's identity: `recordSend`
        // stored the resolution in this row, so its `row_id` is live now.
        // If the partner GCs this position and reuses it before `step`
        // encodes, the stamp mismatch makes the stale carrier moot.
        const row_id = self.session_state.inboundAnswerRowId(answer) orelse unreachable;
        self.pending_send.pushAssumeCapacity(.{ .settled_answer = .{ .position = answer, .row_id = row_id } });
        return;
    }

    var owned_needs_free = true;
    errdefer if (owned_needs_free) freeMessage(self.allocator, message);

    try self.pending_send.push(self.allocator, .{ .message = message });
    owned_needs_free = false;
    var appended = true;
    errdefer if (appended) self.pending_send.popBack().?.deinit(self.allocator);

    try self.session_state.recordSend(message);
    appended = false;
}

fn answerProducedBy(message: model.Message) ?model.AnswerPosition {
    return switch (message) {
        .deliver => |deliver| deliver.answer,
        .get => |get| get.answer,
        .index => |index| index.answer,
        .untag => |untag| untag.answer,
        else => null,
    };
}

/// Queue a next-profile operation and its mandatory shortening-capable listen
/// as one preparation. Every fallible resource is acquired before `recordSend`
/// commits the operation's answer; the two queue appends are then infallible and
/// preserve wire order.
fn enqueueNextAnsweredOperation(
    self: *Peer,
    message: model.Message,
    answer: model.AnswerPosition,
) !void {
    self.pending_send.ensureUnusedCapacityForOne(self.allocator) catch |err| {
        freeMessage(self.allocator, message);
        return err;
    };

    const resolver_export = self.session_state.mintMentionedResolverExport(answer, .object) catch |err| {
        freeMessage(self.allocator, message);
        return err;
    };
    var resolver_owned = true;
    errdefer if (resolver_owned)
        self.session_state.abandonMentionedResolverExport(resolver_export);

    self.session_state.recordSend(message) catch |err| {
        freeMessage(self.allocator, message);
        return err;
    };

    const listener: model.Message = .{ .listen = .{
        .target = .{ .promise = .{ .answer_position = answer } },
        .listener = session.slot.toReference(self.session_state.exportSlot(resolver_export).?).?,
        .mode = .shortening_or_settling,
    } };
    self.pending_send.pushAssumeCapacity(.{ .next_answered = .{
        .operation = message,
        .listener = listener,
    } });
    resolver_owned = false;
}

/// Encode the front pending-send item during `step`. A store-backed
/// `settled_answer` remains queued until encode succeeds because its POD
/// carrier is retry-safe. The other arms transfer ownership before encode:
/// their path may install session authority, so replay after a later failure
/// is not generally safe.
pub fn stepPending(self: *Peer) !void {
    const front = self.pending_send.peek().?.*;
    switch (front) {
        .settled_answer => |sa| {
            // The resolution lives in the answer store (it moved there at
            // record time); borrow it to encode and to drive the local
            // settlement, the store keeps owning it. Moot when the row is
            // gone (an inbound `op:gc-answers` dropped it — its pipelined
            // calls, projections, and listeners were freed with it) or when
            // the position was reused by a fresh answer whose `row_id` no
            // longer matches: `resolveStoreChecked` guards both, so the
            // reused row's payload is never resolved under this carrier.
            const stored = resolveStoreChecked(self, .{ .answer = .{ .position = sa.position, .row_id = sa.row_id } }) orelse {
                discardPendingFront(self);
                return;
            };
            const resolve: model.Resolve = .{ .answer = sa.position, .resolution = stored.* };
            // V1.0 sends the settlement through its resolver callback. The
            // next profile has no wire op:resolve: its mandatory op:listen is
            // the notification path, so only the local consequence drain runs.
            if (self.session_state.captp_version == .v1_0)
                try emitOutboundMessage(self, .{ .resolve = resolve });
            // Once notification is committed (or, on next, deliberately
            // omitted), a consequence-drain failure must not retain the
            // carrier and repeat the settlement on retry.
            discardPendingFront(self);
            // A sent `op:resolve` also settles one of our inbound answers locally.
            try settleSentResolve(self, resolve);
        },
        .next_answered => |pair| try stepNextAnswered(self, pair),
        .message, .listener_fire => try stepConsumedPending(
            self,
            self.pending_send.consumeFront(self.allocator),
        ),
    }
}

fn stepNextAnswered(self: *Peer, pair: NextAnswered) !void {
    var operation_frame = try codec.dispatch.encodeMessageForProfile(
        self.session_state.codec,
        self.allocator,
        self.session_state.captp_version,
        pair.operation,
    );
    errdefer operation_frame.deinit();
    var listener_frame = try codec.dispatch.encodeMessageForProfile(
        self.session_state.codec,
        self.allocator,
        self.session_state.captp_version,
        pair.listener,
    );
    errdefer listener_frame.deinit();
    try self.outbound.ensureUnusedCapacity(self.allocator, 2);

    self.outbound.pushAssumeCapacity(operation_frame);
    self.outbound.pushAssumeCapacity(listener_frame);
    self.pending_send.consumeFront(self.allocator).deinit(self.allocator);
}

fn stepConsumedPending(self: *Peer, item: Outbound) !void {
    switch (item) {
        .message => |message| {
            defer freeMessage(self.allocator, message);
            try emitOutboundMessage(self, message);
        },
        .listener_fire => |fire| {
            var args: [2]model.Argument = undefined;
            const message = switch (fire.target) {
                // CapTP already-settled object export: the payload is POD
                // `fulfill(near)` rebuilt from the carrier's position. Moot
                // when the export row is gone (a partner `op:gc-exports`
                // between queue and encode) or no longer a live object slot.
                .near_object => |export_position| blk: {
                    const slot = self.session_state.exportSlot(export_position) orelse return;
                    if (slot != .local_value) return;
                    const resolution: model.Resolution = .{ .fulfill = .{
                        .reference = .{ .near = model.NearRef.object(export_position.int()) },
                    } };
                    break :blk pipeline.borrowedListenerFire(fire.listener_position, resolution, &args);
                },
                // Borrow the fire's payload from whichever store holds it and
                // encode, through the same `resolveStoreChecked` guard
                // `settled_answer` uses. The fire is moot when the row is gone
                // (an inbound `op:gc-answers` dropped an answer, or GC
                // co-eviction tore down an imported promise) or when a surviving
                // row's `row_id` no longer matches — a partner released and
                // reused an answer position, or an imported row was re-registered
                // as a *different* third-party promise. Either way the stale
                // fire's accounting names the dead instance's payload, so nothing
                // emits. (The queue-time export retains of a dropped fire stay
                // recorded until session end, the same stranded-retain posture a
                // GC'd `settled_answer` ships.)
                .store => |store_target| blk: {
                    const stored = resolveStoreChecked(self, store_target) orelse return;
                    break :blk pipeline.borrowedListenerFire(fire.listener_position, stored.*, &args);
                },
            };
            try emitOutboundMessage(self, message);
        },
        .settled_answer, .next_answered => unreachable,
    }
}

fn discardPendingFront(self: *Peer) void {
    self.pending_send.consumeFront(self.allocator).deinit(self.allocator);
}

/// The current row id and borrowed stored resolution behind a fire target,
/// or null when the store row is gone or has no resolution yet. The one
/// lookup both the fire enqueue (for the stamp) and `step` (to encode) read,
/// so the answer store and the imported-promise store are reached the same
/// way. The returned resolution borrows the store; it is valid only until
/// the store is next mutated.
fn resolveFireStore(self: *Peer, target: StoreTarget) ?struct {
    row_id: u64,
    resolution: *const model.Resolution,
} {
    switch (target) {
        .answer => |answer| {
            const row_id = self.session_state.inboundAnswerRowId(answer.position) orelse return null;
            const resolution = self.session_state.peekResolution(answer.position) orelse return null;
            return .{ .row_id = row_id, .resolution = resolution };
        },
        .import => |import| {
            const row = self.session_state.findImportedPromise(import.position) orelse return null;
            if (row.cell.resolution) |*resolution| return .{ .row_id = row.cell.row_id, .resolution = resolution };
            return null;
        },
    }
}

/// The borrowed stored resolution behind `target`, but only when the store
/// row still carries the stamp the target's arm was queued with. It is the one
/// guard both queued store-borrow carriers apply at encode. A row that is
/// gone, has no resolution yet, or whose identity changed (a partner reused
/// an answer position, or an imported promise row was torn down and
/// re-registered) fails to match, so the stale carrier emits nothing rather
/// than the reused row's payload. `settled_answer` and `listener_fire` read
/// the store through this one seam.
pub fn resolveStoreChecked(self: *Peer, target: StoreTarget) ?*const model.Resolution {
    const found = resolveFireStore(self, target) orelse return null;
    const stamped = switch (target) {
        .answer => |answer| answer.row_id,
        .import => |import| import.row_id,
    };
    if (found.row_id != stamped) return null;
    return found.resolution;
}

/// Encode one popped pending message onto `outbound`, applying the V1.0
/// translations that have no wire form under next (`v1_0`, ADR-0010):
///   - a semantic `Resolve` ships as a resolver-callback `op:deliver` to the
///     partner's resolver import, or is dropped when only `op:listen`
///     listeners settle the answer (the listener fire in `settleSentResolve`
///     handles notification);
///   - an answered `op:deliver` gains a synthesized resolver export at encode
///     time, committing the resolver link as it does;
///   - a projection trails an `op:listen` that carries its new answer's
///     resolution back, since the projection ops carry no inline resolver
///     (ADR-0050, ADR-0052). The listen must follow the op that opened the
///     answer on the wire, so it is pushed after the encode.
/// next encodes the message as it stands. Borrows `message`; the caller
/// owns and frees it. An `op:abort` goes through `commitAbortOutbound`
/// (close after successful push) so the partner can still take the frame.
fn emitOutboundMessage(self: *Peer, message: model.Message) !void {
    if (message == .abort) {
        try self.commitAbortOutbound(message.abort);
        return;
    }

    const needs_v1_0 = self.session_state.needsV1_0Translation();

    if (needs_v1_0 and message == .resolve) {
        // A V1.0 partner hears a resolution only through the resolver
        // capability its own deliver carried (`resolve-me-desc`). A deliver
        // that named an answer but advertised no resolver asked for no
        // callback: there is nobody to notify, so the resolve emits nothing —
        // V1.0 has no wire shape to invent for it.
        if (self.session_state.resolverForInboundAnswer(message.resolve.answer)) |resolver_import| {
            try v1_0.encodeResolveAsCallback(self, message.resolve, resolver_import);
        }
        return;
    }

    const wire_message = if (needs_v1_0 and message == .deliver)
        try v1_0.installResolverForOutboundDeliver(self, message.deliver)
    else
        message;
    try self.pushEncoded(wire_message);

    if (needs_v1_0) switch (message) {
        .get => |g| try v1_0.installListenerForOutboundProjection(self, g.answer),
        .index => |i| try v1_0.installListenerForOutboundProjection(self, i.answer),
        .untag => |u| try v1_0.installListenerForOutboundProjection(self, u.answer),
        else => {},
    };
}

/// Settle the local consequences of a just-sent `op:resolve`: drain the
/// calls the partner pipelined against the answer and the projections
/// anchored on it (calls first — a drained call may settle further answers,
/// ADR-0007 § Queue ownership and drain), then fire its listeners. The
/// resolution itself is already stored — `applySentResolve` stored it when
/// this resolve was recorded (`recordSend` routes a sent resolve there), the
/// same moment the answer's status flipped — so a
/// pipelined call, projection, or `op:listen` that arrived between record and
/// this emit already saw the settled answer with its value on hand and was
/// served directly; only the calls / projections / listeners that anchored
/// while the answer was still pending remain for these drains. The resolution
/// frame is already on `outbound`, so a drain refusal surfaces as a step
/// error without un-sending it. Borrows `resolve`; the caller owns and frees
/// it.
fn settleSentResolve(self: *Peer, resolve: model.Resolve) !void {
    try pipeline.drainResolveConsequences(self, resolve);
}
