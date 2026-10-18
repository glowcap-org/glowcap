//! Prepare/commit transactions for promise shortening consequences.
//!
//! Inbound validation decides semantics. This leaf owns the fallible authority
//! and queue reservations that must all exist before a received frame commits.

const std = @import("std");

const model = @import("model");
const session = @import("session");
const events = @import("events.zig");
const engine = @import("mod.zig");
const Peer = engine.Peer;

pub const PreparedShortening = struct {
    nominations: std.ArrayListUnmanaged(session.ShorteningNomination) = .empty,
    reservations: std.ArrayListUnmanaged(engine.Peer.PendingReservation) = .empty,

    pub fn abandon(self: *PreparedShortening, peer: *Peer) void {
        for (self.reservations.items) |reservation| peer.cancelPendingReservation(reservation);
        self.reservations.deinit(peer.allocator);
        for (self.nominations.items) |nomination|
            peer.session_state.abandonShorteningResolver(nomination);
        self.nominations.deinit(peer.allocator);
        self.* = .{};
    }
};

pub const PreparedOutboundMessage = struct {
    message: model.Message,
    reservation: engine.Peer.PendingReservation,
    closure_len: usize = 0,
};

/// The validated input and exact source state for one private shortening
/// callback. It carries the facts needed to reserve its complete consequence
/// batch before the inbound deliver is applied.
pub const ShorteningCallbackPlan = struct {
    resolver: model.ExportPosition,
    shortened_to: model.FarRef,
    source: session.PromiseIncarnation,
    /// The application still holds the source promise, so the move keeps its
    /// import and nominates shortening for the introduced promise. Released,
    /// the introduced promise's mention goes back as one `op:gc-export`.
    source_is_held: bool,
    /// A settling consumer (an answer or the Node) follows the source, so its
    /// settling listener moves onto the target.
    has_settling_consumer: bool,
    /// The source claimed a settling listener, which a move without a
    /// consumer discards.
    source_has_settling: bool,

    /// Validate the borrowed resolver callback and identify the exact source
    /// incarnation before any callback-specific state is changed.
    pub fn init(
        peer: *Peer,
        resolver: model.ExportPosition,
        body: *const model.view.Body,
        introduced: *session.validate.IntroducedImports,
    ) !ShorteningCallbackPlan {
        const resolution = try events.resolutionFromResolverCallback(body.deliver.args);
        const shortened_to: model.FarRef = switch (resolution) {
            .fulfill => |arg| switch (arg) {
                .reference => |reference| switch (reference) {
                    .far => |far| if (far.kind == .promise) far else return error.UnexpectedMessage,
                    else => return error.UnexpectedMessage,
                },
                else => return error.UnexpectedMessage,
            },
            .@"break" => return error.UnexpectedMessage,
        };
        try peer.session_state.validateShorteningCompletion(resolver, shortened_to);
        try peer.session_state.validateInboundDeliverView(body, introduced);

        const source = switch (peer.session_state.sourceForShorteningResolver(resolver).?) {
            .pending => |pending| pending,
            .complete => unreachable,
        };
        return .{
            .resolver = resolver,
            .shortened_to = shortened_to,
            .source = source,
            .source_is_held = peer.session_state.shorteningSourceIsHeld(resolver),
            .has_settling_consumer = peer.session_state.promiseSettlingConsumerClaimed(source),
            .source_has_settling = peer.session_state.promiseSettlingListenerClaimed(source),
        };
    }

    /// Reserve capacity for the existing shortening, release, and optional
    /// settling-rearm carriers as one batch.
    pub fn pendingPreparationCount(
        self: ShorteningCallbackPlan,
        introduced: *const session.validate.IntroducedImports,
    ) usize {
        var count = introduced.promise_mentions.count();
        if (!self.source_is_held) count += 1;
        if (self.has_settling_consumer) count += 1;
        return count;
    }

    /// Acquire every resource the callback's commit may publish. The caller
    /// keeps the shared introduced-import record alive through commit.
    pub fn prepare(
        self: ShorteningCallbackPlan,
        peer: *Peer,
        pending_batch: *engine.Peer.PendingBatch,
        introduced: *const session.validate.IntroducedImports,
    ) !PreparedShorteningCallback {
        var prepared: PreparedShorteningCallback = .{ .plan = self };
        errdefer prepared.abandon(peer);
        // A released source with no consumer keeps nothing of the introduced
        // promise, so it nominates no shortening for it.
        if (self.source_is_held or self.has_settling_consumer)
            prepared.shortening = try prepareIntroducedPromiseShortening(peer, pending_batch, introduced);
        if (!self.source_is_held)
            prepared.late_release = try prepareIntroducedPromiseRelease(peer, pending_batch, self.shortened_to.import_position);
        if (self.has_settling_consumer)
            prepared.settling_rearm = try prepareSettlingRearm(peer, pending_batch, self.source, self.shortened_to.import_position);
        return prepared;
    }
};

/// All fallible work for one private shortening callback, together with its
/// terminal transition. Abandon releases its reservations. Commit transfers
/// every prepared carrier after the validated deliver applies, and leaves the
/// record empty so a later abandon releases nothing.
pub const PreparedShorteningCallback = struct {
    plan: ShorteningCallbackPlan,
    shortening: PreparedShortening = .{},
    late_release: ?PreparedOutboundMessage = null,
    settling_rearm: ?PreparedSettlingRearm = null,

    pub fn abandon(self: *PreparedShorteningCallback, peer: *Peer) void {
        if (self.settling_rearm) |*rearm| rearm.deinit(peer);
        self.settling_rearm = null;
        self.shortening.abandon(peer);
        if (self.late_release) |prepared| abandonPreparedOutboundMessage(peer, prepared);
        self.late_release = null;
    }

    /// Apply the callback's validated imports, then complete its promise move
    /// and publish the maintenance prepared for that exact source incarnation.
    pub fn commit(
        self: *PreparedShorteningCallback,
        peer: *Peer,
        body: *const model.view.Body,
        introduced: *session.validate.IntroducedImports,
    ) !void {
        try peer.session_state.applyValidatedInboundDeliverView(body, introduced);
        peer.session_state.completeShortening(
            self.plan.resolver,
            self.plan.shortened_to,
            self.plan.source_is_held,
        );
        commitPreparedShortening(peer, &self.shortening);
        // `prepareSettlingRearm` is null exactly when the source claimed no
        // settling listener, so a claimed listener with no consumer to move
        // it onto is discarded here.
        if (self.settling_rearm) |rearm|
            commitSettlingRearm(peer, self.plan.source, self.plan.shortened_to, rearm)
        else if (self.plan.source_has_settling)
            peer.session_state.discardUnconsumedPromiseSettlingListener(self.plan.source);
        self.settling_rearm = null;
        if (self.late_release) |prepared| {
            commitPreparedImportRelease(peer, prepared);
            peer.session_state.releaseShorteningSourceAuthority(self.plan.source);
        }
        self.late_release = null;
    }
};

fn abandonPreparedOutboundMessage(peer: *Peer, prepared: PreparedOutboundMessage) void {
    peer.cancelPendingReservation(prepared.reservation);
    model.freeMessage(peer.allocator, prepared.message);
}

pub fn prepareIntroducedPromiseShortening(
    self: *Peer,
    pending_batch: *engine.Peer.PendingBatch,
    introduced: *const session.validate.IntroducedImports,
) !PreparedShortening {
    var prepared: PreparedShortening = .{};
    errdefer prepared.abandon(self);
    if (self.session_state.captp_version != .next or introduced.promise_mentions.count() == 0) return prepared;

    try prepared.nominations.ensureTotalCapacity(self.allocator, introduced.promise_mentions.count());
    try prepared.reservations.ensureTotalCapacity(self.allocator, introduced.promise_mentions.count());
    for (introduced.promise_mentions.items()) |source| {
        const nomination = (try self.session_state.nominateShorteningResolver(source)) orelse continue;
        prepared.nominations.appendAssumeCapacity(nomination);
        const message = shorteningListen(self, nomination);
        prepared.reservations.appendAssumeCapacity(try pending_batch.reserve(.{ .message = message }));
    }
    return prepared;
}

pub fn commitPreparedShortening(self: *Peer, prepared: *PreparedShortening) void {
    // A message that prepared nothing holds nothing to commit or free.
    if (prepared.nominations.capacity == 0) return;
    for (prepared.nominations.items, prepared.reservations.items) |nomination, reservation| {
        const message = shorteningListen(self, nomination);
        self.session_state.recordPreparedSend(message);
        self.pushPendingAssume(reservation, .{ .message = message });
    }
    prepared.nominations.deinit(self.allocator);
    prepared.reservations.deinit(self.allocator);
    prepared.* = .{};
}

/// The `op:listen` that nominates `nomination`'s resolver export to shorten
/// its source promise. Built at prepare to measure and at commit to send,
/// because the message borrows nothing and holds no reservation.
fn shorteningListen(peer: *const Peer, nomination: session.ShorteningNomination) model.Message {
    return .{ .listen = .{
        .target = .{ .far = model.FarRef.promise(nomination.source.int()) },
        .listener = peer.session_state.exportReference(nomination.resolver_export).?,
        .mode = .shortening_only,
    } };
}

/// The `op:listen` that moves `listener`'s settling subscription onto `target`.
fn settlingListen(peer: *const Peer, listener: model.ExportPosition, target: model.FarRef) model.Message {
    return .{ .listen = .{
        .target = .{ .far = target },
        .listener = peer.session_state.exportReference(listener).?,
        .mode = .settling_only,
    } };
}

pub const PreparedSettlingRearm = struct {
    listener_export: model.ExportPosition,
    /// The listener export the Node's shortening row names: the target's own
    /// settling listener when the move converges, else `listener_export`.
    node_listener_export: model.ExportPosition,
    node_services: ?engine.NodeServices,
    move: session.SettlingMovePlan,
    reservation: ?engine.Peer.PendingReservation = null,

    pub fn deinit(self: *PreparedSettlingRearm, peer: *Peer) void {
        if (self.reservation) |reservation| peer.cancelPendingReservation(reservation);
        self.move.deinit(peer.allocator);
    }
};

pub fn prepareSettlingRearm(
    self: *Peer,
    pending_batch: *engine.Peer.PendingBatch,
    source: session.PromiseIncarnation,
    target: model.ImportPosition,
) !?PreparedSettlingRearm {
    if (!self.session_state.promiseSettlingListenerClaimed(source)) return null;
    var move = try self.session_state.preparePromiseSettlingMove(source, target);
    var move_is_owned = true;
    errdefer if (move_is_owned) move.deinit(self.allocator);

    const answer = self.session_state.promiseSettlingAnswer(source);
    const source_listener = self.session_state.promiseSettlingListenerExport(source) orelse
        return error.UnexpectedMessage;
    const target_incarnation = self.session_state.shorteningIncarnationForImport(target) orelse
        return error.UnexpectedMessage;
    const target_listener = if (move.converges)
        self.session_state.promiseSettlingListenerExport(target_incarnation) orelse
            return error.UnexpectedMessage
    else
        source_listener;
    const node_services = if (self.session_state.promiseSettlingNodeClaimed(source)) blk: {
        const services = self.node_services orelse return error.UnexpectedMessage;
        try services.preparePromiseShortening(source.position.int(), target.int());
        break :blk services;
    } else null;
    if (answer == null and node_services == null) return error.UnexpectedMessage;
    var prepared: PreparedSettlingRearm = .{
        .listener_export = source_listener,
        .node_listener_export = target_listener,
        .node_services = node_services,
        .move = move,
    };
    move_is_owned = false;
    errdefer prepared.deinit(self);
    if (!prepared.move.converges) {
        const message = settlingListen(self, prepared.listener_export, model.FarRef.promise(target.int()));
        prepared.reservation = try pending_batch.reserve(.{ .message = message });
    }
    return prepared;
}

pub fn commitSettlingRearm(
    self: *Peer,
    source: session.PromiseIncarnation,
    target: model.FarRef,
    prepared_in: PreparedSettlingRearm,
) void {
    var prepared = prepared_in;
    if (!prepared.move.converges) {
        const message = settlingListen(self, prepared.listener_export, target);
        self.session_state.recordPreparedSend(message);
        self.pushPendingAssume(prepared.reservation.?, .{ .message = message });
        prepared.reservation = null;
    }
    self.session_state.commitPromiseSettlingMove(&prepared.move);
    if (prepared.node_services) |services|
        services.commitPromiseShortening(
            source.position.int(),
            target.import_position.int(),
            prepared.node_listener_export.int(),
            prepared.move.converges,
        );
}

pub fn prepareIntroducedPromiseRelease(
    self: *Peer,
    pending_batch: *engine.Peer.PendingBatch,
    position: model.ImportPosition,
) !PreparedOutboundMessage {
    return (try prepareIntroducedImportReleases(self, pending_batch, &.{position})).?;
}

pub fn prepareIntroducedImportReleases(
    self: *Peer,
    pending_batch: *engine.Peer.PendingBatch,
    imports: []const model.ImportPosition,
) !?PreparedOutboundMessage {
    const message = (try session.ImportRelease.messageForMentions(self.allocator, imports)) orelse return null;
    errdefer model.freeMessage(self.allocator, message);
    return .{ .message = message, .reservation = try pending_batch.reserve(.{ .message = message }) };
}

pub fn commitPreparedImportRelease(self: *Peer, prepared: PreparedOutboundMessage) void {
    if (prepared.closure_len == 0) {
        self.session_state.recordPreparedSend(prepared.message);
    } else {
        const gc = prepared.message.gc_export;
        const own = gc.positions.len - prepared.closure_len;
        self.session_state.recordPreparedSend(.{ .gc_export = .{ .positions = gc.positions[0..own], .deltas = gc.deltas[0..own] } });
        self.session_state.recordSessionImportRelease(.{ .positions = gc.positions[own..], .deltas = gc.deltas[own..] });
    }
    self.pushPendingAssume(prepared.reservation, .{ .message = prepared.message });
}
