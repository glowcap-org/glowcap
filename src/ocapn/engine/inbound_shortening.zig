//! Prepare/commit transactions for promise shortening consequences.
//!
//! Inbound validation decides semantics; this leaf owns the fallible authority
//! and queue reservations that must all exist before a received frame commits.

const std = @import("std");

const model = @import("model");
const session = @import("session");
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
        self.session_state.recordSend(message) catch unreachable;
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
    shortening_send_count: usize,
) !?PreparedSettlingRearm {
    if (!self.session_state.promiseSettlingListenerClaimed(source)) return null;
    var move = try self.session_state.preparePromiseSettlingMove(source, target);
    errdefer move.deinit(self.allocator);

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
    _ = shortening_send_count;
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
        self.session_state.recordSend(message) catch unreachable;
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
    self.session_state.recordSend(prepared.message) catch unreachable;
    self.pushPendingAssume(prepared.reservation, .{ .message = prepared.message });
}
