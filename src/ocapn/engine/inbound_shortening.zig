//! Prepare/commit transactions for promise shortening consequences.
//!
//! Inbound validation decides semantics; this leaf owns the fallible authority
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
};

/// The validated input and exact source state for one private shortening
/// callback. It carries the facts needed to reserve its complete consequence
/// batch before the inbound deliver is applied.
const ShorteningCallbackState = enum {
    held,
    held_with_settling_consumer,
    released,
    released_with_settling_consumer,
};

pub const ShorteningCallbackPlan = struct {
    resolver: model.ExportPosition,
    shortened_to: model.FarRef,
    source: session.PromiseIncarnation,
    state: ShorteningCallbackState,
    source_has_settling: bool,

    /// Validate the borrowed resolver callback and identify the exact source
    /// incarnation before any callback-specific state is changed.
    pub fn init(
        peer: *Peer,
        resolver: model.ExportPosition,
        deliver: model.view.Deliver,
        introduced: *session.validate.IntroducedImports,
    ) !ShorteningCallbackPlan {
        const resolution = try events.resolutionFromResolverCallback(deliver.args);
        const shortened_to: model.FarRef = switch (resolution) {
            .fulfill => |arg| switch (arg) {
                .reference => |reference| switch (reference) {
                    .far => |far| if (far.kind == .promise) far else return session.Error.UnexpectedMessage,
                    else => return session.Error.UnexpectedMessage,
                },
                else => return session.Error.UnexpectedMessage,
            },
            .@"break" => return session.Error.UnexpectedMessage,
        };
        try peer.session_state.validateShorteningCompletion(resolver, shortened_to);
        try peer.session_state.validateInboundDeliverView(deliver, introduced);

        const source = switch (peer.session_state.sourceForShorteningResolver(resolver).?) {
            .pending => |pending| pending,
            .complete => unreachable,
        };
        const source_is_held = peer.session_state.shorteningSourceIsHeld(resolver);
        const source_has_settling_consumer = peer.session_state.promiseSettlingConsumerClaimed(source);
        return .{
            .resolver = resolver,
            .shortened_to = shortened_to,
            .source = source,
            .state = if (source_is_held)
                (if (source_has_settling_consumer) .held_with_settling_consumer else .held)
            else if (source_has_settling_consumer)
                .released_with_settling_consumer
            else
                .released,
            .source_has_settling = peer.session_state.promiseSettlingListenerClaimed(source),
        };
    }

    fn sourceIsHeld(self: ShorteningCallbackPlan) bool {
        return switch (self.state) {
            .held, .held_with_settling_consumer => true,
            .released, .released_with_settling_consumer => false,
        };
    }

    fn hasSettlingConsumer(self: ShorteningCallbackPlan) bool {
        return switch (self.state) {
            .held_with_settling_consumer, .released_with_settling_consumer => true,
            .held, .released => false,
        };
    }

    /// Reserve capacity for the existing shortening, release, and optional
    /// settling-rearm carriers as one batch.
    pub fn pendingPreparationCount(
        self: ShorteningCallbackPlan,
        introduced: *const session.validate.IntroducedImports,
    ) usize {
        var count = introduced.promise_mentions.items.len;
        if (!self.sourceIsHeld()) count += 1;
        if (self.hasSettlingConsumer()) count += 1;
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
        return switch (self.state) {
            .held => .{
                .plan = self,
                .resources = .{ .held = try prepareIntroducedPromiseShortening(
                    peer,
                    pending_batch,
                    introduced,
                ) },
            },
            .held_with_settling_consumer => blk: {
                var shortening = try prepareIntroducedPromiseShortening(peer, pending_batch, introduced);
                errdefer shortening.abandon(peer);
                const settling_rearm = try prepareSettlingRearm(
                    peer,
                    pending_batch,
                    self.source,
                    self.shortened_to.import_position,
                );
                break :blk .{
                    .plan = self,
                    .resources = .{ .held_with_settling_consumer = .{
                        .shortening = shortening,
                        .settling_rearm = settling_rearm,
                    } },
                };
            },
            .released => .{
                .plan = self,
                .resources = .{ .released = try prepareIntroducedPromiseRelease(
                    peer,
                    pending_batch,
                    self.shortened_to.import_position,
                ) },
            },
            .released_with_settling_consumer => blk: {
                var shortening = try prepareIntroducedPromiseShortening(peer, pending_batch, introduced);
                errdefer shortening.abandon(peer);
                const late_release = try prepareIntroducedPromiseRelease(
                    peer,
                    pending_batch,
                    self.shortened_to.import_position,
                );
                errdefer abandonPreparedOutboundMessage(peer, late_release);
                const settling_rearm = try prepareSettlingRearm(
                    peer,
                    pending_batch,
                    self.source,
                    self.shortened_to.import_position,
                );
                break :blk .{
                    .plan = self,
                    .resources = .{ .released_with_settling_consumer = .{
                        .shortening = shortening,
                        .late_release = late_release,
                        .settling_rearm = settling_rearm,
                    } },
                };
            },
        };
    }
};

/// All fallible work for one private shortening callback, together with its
/// terminal transition. Abandon releases its reservations; commit transfers
/// every prepared carrier after the validated deliver applies.
pub const PreparedShorteningCallback = struct {
    plan: ShorteningCallbackPlan,
    resources: union(enum) {
        held: PreparedShortening,
        held_with_settling_consumer: struct {
            shortening: PreparedShortening,
            settling_rearm: ?PreparedSettlingRearm,
        },
        released: PreparedOutboundMessage,
        released_with_settling_consumer: struct {
            shortening: PreparedShortening,
            late_release: PreparedOutboundMessage,
            settling_rearm: ?PreparedSettlingRearm,
        },
        committed: void,
    },

    pub fn abandon(self: *PreparedShorteningCallback, peer: *Peer) void {
        switch (self.resources) {
            .held => |*prepared| prepared.abandon(peer),
            .held_with_settling_consumer => |*prepared| {
                if (prepared.settling_rearm) |*rearm| rearm.deinit(peer);
                prepared.shortening.abandon(peer);
            },
            .released => |*prepared| abandonPreparedOutboundMessage(peer, prepared.*),
            .released_with_settling_consumer => |*prepared| {
                if (prepared.settling_rearm) |*rearm| rearm.deinit(peer);
                prepared.shortening.abandon(peer);
                abandonPreparedOutboundMessage(peer, prepared.late_release);
            },
            .committed => {},
        }
        self.resources = .committed;
    }

    /// Apply the callback's validated imports, then complete its promise move
    /// and publish the maintenance prepared for that exact source incarnation.
    pub fn commit(
        self: *PreparedShorteningCallback,
        peer: *Peer,
        deliver: model.view.Deliver,
        introduced: *session.validate.IntroducedImports,
    ) !void {
        try peer.session_state.applyValidatedInboundDeliverView(deliver, introduced);
        peer.session_state.completeShortening(
            self.plan.resolver,
            self.plan.shortened_to,
            self.plan.sourceIsHeld(),
        );

        switch (self.resources) {
            .held => |*prepared| {
                commitPreparedShortening(peer, prepared);
                if (self.plan.source_has_settling)
                    peer.session_state.discardUnconsumedPromiseSettlingListener(self.plan.source);
            },
            .held_with_settling_consumer => |*prepared| {
                commitPreparedShortening(peer, &prepared.shortening);
                if (prepared.settling_rearm) |rearm|
                    commitSettlingRearm(peer, self.plan.source, self.plan.shortened_to, rearm);
            },
            .released => |*prepared| {
                if (self.plan.source_has_settling)
                    peer.session_state.discardUnconsumedPromiseSettlingListener(self.plan.source);
                commitPreparedImportRelease(peer, prepared.*);
                peer.session_state.releaseShorteningSourceAuthority(self.plan.source);
            },
            .released_with_settling_consumer => |*prepared| {
                commitPreparedShortening(peer, &prepared.shortening);
                if (prepared.settling_rearm) |rearm|
                    commitSettlingRearm(peer, self.plan.source, self.plan.shortened_to, rearm);
                commitPreparedImportRelease(peer, prepared.late_release);
                peer.session_state.releaseShorteningSourceAuthority(self.plan.source);
            },
            .committed => unreachable,
        }
        self.resources = .committed;
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
    if (self.session_state.captp_version != .next) return prepared;

    try prepared.nominations.ensureTotalCapacity(self.allocator, introduced.promise_mentions.items.len);
    try prepared.reservations.ensureTotalCapacity(self.allocator, introduced.promise_mentions.items.len);
    for (introduced.promise_mentions.items) |source| {
        const nomination = (try self.session_state.nominateShorteningResolver(source)) orelse continue;
        prepared.nominations.appendAssumeCapacity(nomination);
        const message: model.Message = .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(nomination.source.int()) },
            .listener = session.slot.toReference(self.session_state.exportSlot(nomination.resolver_export).?).?,
            .mode = .shortening_only,
        } };
        prepared.reservations.appendAssumeCapacity(try pending_batch.reserve(.{ .message = message }));
    }
    return prepared;
}

pub fn commitPreparedShortening(self: *Peer, prepared: *PreparedShortening) void {
    for (prepared.nominations.items, prepared.reservations.items) |nomination, reservation| {
        const message: model.Message = .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(nomination.source.int()) },
            .listener = session.slot.toReference(self.session_state.exportSlot(nomination.resolver_export).?).?,
            .mode = .shortening_only,
        } };
        self.session_state.recordPreparedSend(message);
        self.pushPendingAssume(reservation, .{ .message = message });
    }
    prepared.nominations.deinit(self.allocator);
    prepared.reservations.deinit(self.allocator);
    prepared.* = .{};
}

pub const PreparedSettlingRearm = struct {
    listener_export: model.ExportPosition,
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
        return session.Error.UnexpectedMessage;
    const target_incarnation = self.session_state.shorteningIncarnationForImport(target) orelse
        return session.Error.UnexpectedMessage;
    const target_listener = if (move.converges)
        self.session_state.promiseSettlingListenerExport(target_incarnation) orelse
            return session.Error.UnexpectedMessage
    else
        source_listener;
    const node_services = if (self.session_state.promiseSettlingNodeClaimed(source)) blk: {
        const services = self.node_services orelse return session.Error.UnexpectedMessage;
        try services.preparePromiseShortening(
            source.position.int(),
            target.int(),
            target_listener.int(),
            move.converges,
        );
        break :blk services;
    } else null;
    if (answer == null and node_services == null) return session.Error.UnexpectedMessage;
    var prepared: PreparedSettlingRearm = .{
        .listener_export = source_listener,
        .node_services = node_services,
        .move = move,
    };
    move_is_owned = false;
    errdefer prepared.deinit(self);
    if (!prepared.move.converges) {
        const message: model.Message = .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(target.int()) },
            .listener = session.slot.toReference(self.session_state.exportSlot(prepared.listener_export).?).?,
            .mode = .settling_only,
        } };
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
        const message: model.Message = .{ .listen = .{
            .target = .{ .far = target },
            .listener = session.slot.toReference(self.session_state.exportSlot(prepared.listener_export).?).?,
            .mode = .settling_only,
        } };
        self.session_state.recordPreparedSend(message);
        self.pushPendingAssume(prepared.reservation.?, .{ .message = message });
        prepared.reservation = null;
    }
    self.session_state.commitPromiseSettlingMove(&prepared.move);
    if (prepared.node_services) |services|
        services.commitPromiseShortening(
            source.position.int(),
            target.import_position.int(),
            if (prepared.move.converges)
                self.session_state.promiseSettlingListenerExport(
                    self.session_state.shorteningIncarnationForImport(target.import_position) orelse unreachable,
                ).?.int()
            else
                prepared.listener_export.int(),
            prepared.move.converges,
        );
}

pub fn prepareIntroducedPromiseRelease(
    self: *Peer,
    pending_batch: *engine.Peer.PendingBatch,
    position: model.ImportPosition,
) !PreparedOutboundMessage {
    const positions = try self.allocator.alloc(u64, 1);
    errdefer self.allocator.free(positions);
    const deltas = try self.allocator.alloc(u64, 1);
    errdefer self.allocator.free(deltas);
    positions[0] = position.int();
    deltas[0] = 1;
    const message: model.Message = .{ .gc_export = .{ .positions = positions, .deltas = deltas } };
    return .{ .message = message, .reservation = try pending_batch.reserve(.{ .message = message }) };
}

pub fn prepareIntroducedImportReleases(
    self: *Peer,
    pending_batch: *engine.Peer.PendingBatch,
    imports: []const model.ImportPosition,
) !?PreparedOutboundMessage {
    if (imports.len == 0) return null;
    const positions = try self.allocator.alloc(u64, imports.len);
    errdefer self.allocator.free(positions);
    const deltas = try self.allocator.alloc(u64, imports.len);
    errdefer self.allocator.free(deltas);
    for (imports, positions, deltas) |import_position, *position, *delta| {
        position.* = import_position.int();
        delta.* = 1;
    }
    const message: model.Message = .{ .gc_export = .{ .positions = positions, .deltas = deltas } };
    return .{ .message = message, .reservation = try pending_batch.reserve(.{ .message = message }) };
}

pub fn commitPreparedImportRelease(self: *Peer, prepared: PreparedOutboundMessage) void {
    self.session_state.recordPreparedSend(prepared.message);
    self.pushPendingAssume(prepared.reservation, .{ .message = prepared.message });
}
