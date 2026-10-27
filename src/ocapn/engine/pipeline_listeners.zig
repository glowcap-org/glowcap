//! Listener installation and settlement drain for the CapTP pipeline seam.
//!
//! Answer, imported-promise, and live-export listeners share one transactional
//! publication path: reserve, record wire accounting, then infallibly publish a
//! stamped store reference. No listener is detached without a terminal owner.

const std = @import("std");

const model = @import("model");
const session = @import("session");

const engine = @import("mod.zig");
const resolution_math = @import("pipeline_resolution.zig");
const resolution_chain = @import("resolution_chain.zig");
const Peer = engine.Peer;
const borrowedListenerFire = resolution_math.borrowedListenerFire;
fn classifyTerminalListenerDrain(peer: *const Peer, entry: session.ListenerEntry, resolution: model.Resolution) resolution_math.ListenerDrainAction {
    return resolution_math.classifyListenerDrain(entry, resolution, peer.session_state.captp_version);
}

const InboundListenClass = union(enum) {
    answer: model.AnswerName,
    live_export: model.ExportPosition,
};

fn classifyInboundListenTarget(peer: *Peer, listen: model.view.Listen) InboundListenClass {
    switch (listen.target) {
        .promise => |promise| return .{ .answer = .fromWire(promise.answer_position) },
        .near => |near| {
            if (peer.session_state.exportSlot(near.export_position)) |export_slot| {
                if (export_slot == .local_unresolved) if (peer.session_state.answerForLocalPromiseExport(near.export_position)) |answer|
                    return .{ .answer = answer };
            }
            return .{ .live_export = near.export_position };
        },
        // `validateInboundListen` ran first, and its target rule
        // (`validateDeliverOrListenTarget`, received perspective) admits only
        // `.near` and `.promise`.
        .far, .routed, .sturdy, .broken => unreachable,
    }
}

pub fn maybeInstallInboundListener(peer: *Peer, listen: model.view.Listen) !void {
    try peer.session_state.validateInboundListen(listen);
    switch (classifyInboundListenTarget(peer, listen)) {
        .answer => |answer| try installAnswerListener(peer, answer, listen),
        .live_export => |export_position| try installExportListener(peer, export_position, listen),
    }
}

/// The listener's mention is the session's to release, beside the fire that
/// spends it or when the listener is discarded. It is never an application
/// reference, so no caller's `op:gc-exports` may address it.
fn listenerEntryFromListen(peer: *Peer, listen: model.view.Listen) !session.ListenerEntry {
    const position = listen.listener.position() orelse return error.InvalidReference;
    try peer.session_state.retainImportForSession(model.ImportPosition.from(position));
    return .{ .listener = model.FarRef.object(position), .mode = listen.mode };
}

fn installAnswerListener(peer: *Peer, answer: model.AnswerName, listen: model.view.Listen) !void {
    const listener_entry = try listenerEntryFromListen(peer, listen);
    var retain_live = true;
    errdefer if (retain_live)
        peer.session_state.releaseSessionImportRetain(listener_entry.listener.import_position);
    if (peer.session_state.peekStoredResolutionNamed(answer)) |resolution| {
        const target = peer.session_state.answerTargetNamed(answer) orelse return error.InvalidReference;
        const payload = peer.session_state.answerPayloadForTarget(target) orelse return error.InvalidReference;
        try applyStoredListener(
            peer,
            .{ .target = .{ .target = target, .payload = payload }, .stored = resolution },
            listener_entry,
        );
    } else {
        try peer.session_state.installListenerNamed(answer, listener_entry);
    }
    retain_live = false;
}

fn installExportListener(peer: *Peer, export_position: model.ExportPosition, listen: model.view.Listen) !void {
    if (peer.session_state.exportSlot(export_position)) |export_slot| {
        if (export_slot == .local_value) {
            try fireLiveObjectExportListener(peer, export_position, listen);
            return;
        }
    }
    return error.InvalidReference;
}

fn fireLiveObjectExportListener(peer: *Peer, export_position: model.ExportPosition, listen: model.view.Listen) !void {
    const listener_entry = try listenerEntryFromListen(peer, listen);
    var retain_live = true;
    errdefer if (retain_live)
        peer.session_state.releaseSessionImportRetain(listener_entry.listener.import_position);
    const resolution: model.Resolution = .{ .fulfill = .{
        .reference = .{ .near = model.NearRef.object(export_position.int()) },
    } };
    switch (classifyTerminalListenerDrain(peer, listener_entry, resolution)) {
        .fire => |position| try enqueueFire(peer, position, .{ .near_object = export_position }, resolution),
        .discard => peer.session_state.releaseSessionImportRetain(listener_entry.listener.import_position),
    }
    retain_live = false;
}

pub fn prepareAnswerListenerDrain(
    peer: *Peer,
    payload: *session.AnswerPayload,
    outcome: resolution_chain.Outcome,
) !PreparedListenerDrain {
    const listeners = try peer.session_state.takeAnswerPayloadListeners(payload);
    if (listeners.len == 0) return .none(payload);
    return prepareListenerDrainPlan(peer, payload, listeners, listenerDrainPlan(outcome));
}

/// What a settled source does with its listeners: re-anchor them on the
/// pending incarnation the chain reached, or fire each with one resolution
/// borrowed from one payload owner.
const ListenerDrainPlan = union(enum) {
    reinstall: session.AnswerTarget,
    fire: Fire,

    const Fire = struct {
        target: engine.FireTarget,
        resolution: model.Resolution,
    };
};

fn terminalBreak(message: []const u8) model.Resolution {
    return .{ .@"break" = .{ .message = message } };
}

fn applyStoredListener(
    peer: *Peer,
    first: resolution_chain.Source,
    entry: session.ListenerEntry,
) !void {
    switch (listenerDrainPlan(resolution_chain.follow(peer, first))) {
        .reinstall => |target| {
            var prepared = try peer.session_state.prepareListenerBatchTarget(target, 1);
            errdefer prepared.abandon(&peer.session_state);
            prepared.commit(&.{entry});
        },
        .fire => |fire| switch (classifyTerminalListenerDrain(peer, entry, fire.resolution)) {
            .fire => |position| try enqueueFire(peer, position, fire.target, fire.resolution),
            .discard => peer.session_state.releaseSessionImportRetain(entry.listener.import_position),
        },
    }
}

pub const PreparedListenerDrain = struct {
    /// The payload whose listeners were taken; `abandon` gives them back.
    source: *session.AnswerPayload,
    listeners: []session.ListenerEntry,
    plan: ListenerDrainPlan,
    reservation: ?Peer.PendingReservation = null,
    reserved: usize = 0,
    target_retains: usize = 0,
    reinstall_prepared: ?session.Session.PreparedListenerBatch = null,
    /// A drain's inventory of the stored tree every fire carries, taken at
    /// prepare so the infallible commit records each fire's mentions from it.
    inventory: session.Inventory = .none,

    /// A drain with nothing to do, for an answer that had no listeners.
    pub fn none(source: *session.AnswerPayload) PreparedListenerDrain {
        return .{ .source = source, .listeners = &.{}, .plan = idle_plan };
    }

    const idle_plan: ListenerDrainPlan = .{ .fire = .{ .target = .{ .static_break = "" }, .resolution = terminalBreak("") } };

    pub fn abandon(self: *PreparedListenerDrain, peer: *Peer) void {
        const source = self.source;
        self.inventory.deinit(peer.allocator);
        if (self.reservation) |reservation| {
            for (0..self.reserved) |_| peer.cancelPendingReservation(reservation);
        }
        if (self.target_retains != 0) {
            std.debug.assert(self.plan == .fire);
            for (0..self.target_retains) |_| releaseFireTarget(peer, self.plan.fire.target);
        }
        if (self.reinstall_prepared) |*prepared| prepared.abandon(&peer.session_state);
        peer.session_state.restoreAnswerPayloadListeners(source, self.listeners);
        self.* = .none(source);
    }

    pub fn commit(self: *PreparedListenerDrain, peer: *Peer) void {
        if (self.listeners.len == 0) {
            self.* = undefined;
            return;
        }
        switch (self.plan) {
            .reinstall => self.reinstall_prepared.?.commit(self.listeners),
            .fire => |fire| for (self.listeners) |entry| switch (classifyTerminalListenerDrain(peer, entry, fire.resolution)) {
                .fire => |position| {
                    var args: [2]model.Argument = undefined;
                    const message = borrowedListenerFire(position, fire.resolution, &args);
                    peer.session_state.commitPreparedListenerFire(message, self.inventory, &args[1]);
                    peer.pushPendingAssume(self.reservation.?, .{ .listener_fire = .{
                        .listener_position = position,
                        .target = fire.target,
                    } });
                },
                .discard => peer.session_state.releaseSessionImportRetain(entry.listener.import_position),
            },
        }
        peer.allocator.free(self.listeners);
        self.inventory.deinit(peer.allocator);
        self.* = undefined;
    }
};

/// A store-backed fire retains its payload box per carrier; a live-object or
/// static-break fire borrows nothing.
fn retainFireTarget(peer: *Peer, target: engine.FireTarget) !void {
    switch (target) {
        .store => |store| try peer.session_state.retainAnswerPayload(store.payload),
        .near_object, .static_break => {},
    }
}

fn releaseFireTarget(peer: *Peer, target: engine.FireTarget) void {
    switch (target) {
        .store => |store| peer.session_state.releaseAnswerPayload(store.payload),
        .near_object, .static_break => {},
    }
}

fn prepareListenerDrainPlan(
    peer: *Peer,
    source: *session.AnswerPayload,
    listeners: []session.ListenerEntry,
    plan: ListenerDrainPlan,
) !PreparedListenerDrain {
    var prepared = PreparedListenerDrain{ .source = source, .listeners = listeners, .plan = plan };
    errdefer prepared.abandon(peer);
    if (prepared.listeners.len == 0) return prepared;
    const fire = switch (prepared.plan) {
        .reinstall => |next_target| {
            prepared.reinstall_prepared =
                try peer.session_state.prepareListenerBatchTarget(next_target, prepared.listeners.len);
            return prepared;
        },
        .fire => |fire| fire,
    };
    var fire_count: usize = 0;
    for (prepared.listeners) |entry| switch (classifyTerminalListenerDrain(peer, entry, fire.resolution)) {
        .fire => {
            try peer.session_state.validateListenerFireTarget(entry.listener);
            fire_count += 1;
        },
        .discard => {},
    };
    if (fire_count == 0) return prepared;
    // Only a stored tree carries mentions to inventory and exports to reserve.
    if (fire.target == .store) {
        prepared.inventory = try peer.inventoryResolution(fire.resolution);
        try peer.session_state.ensureSentResolutionExportCapacity(fire.resolution, prepared.inventory);
    }
    var batch = try peer.beginPendingBatch(fire_count);
    for (prepared.listeners) |entry| switch (classifyTerminalListenerDrain(peer, entry, fire.resolution)) {
        .fire => |position| {
            try retainFireTarget(peer, fire.target);
            prepared.target_retains += 1;
            const reservation = try batch.reserve(.{ .listener_fire = .{
                .listener_position = position,
                .target = fire.target,
            } });
            if (prepared.reservation) |first_reservation|
                std.debug.assert(first_reservation.charge == reservation.charge)
            else
                prepared.reservation = reservation;
            prepared.reserved += 1;
        },
        .discard => {},
    };
    return prepared;
}

fn listenerDrainPlan(outcome: resolution_chain.Outcome) ListenerDrainPlan {
    return switch (outcome) {
        .terminal => |terminal| .{ .fire = .{
            .target = .{ .store = terminal.target },
            .resolution = terminal.resolution,
        } },
        .pending => |target| .{ .reinstall = target },
        .terminal_break => |message| .{ .fire = .{
            .target = .{ .static_break = message },
            .resolution = terminalBreak(message),
        } },
    };
}

fn enqueueFire(
    peer: *Peer,
    listener_position: u64,
    target: engine.FireTarget,
    resolution: model.Resolution,
) !void {
    try retainFireTarget(peer, target);
    errdefer releaseFireTarget(peer, target);
    var args: [2]model.Argument = undefined;
    const borrowed = borrowedListenerFire(listener_position, resolution, &args);
    const reservation = try peer.reservePending(.{ .listener_fire = .{
        .listener_position = listener_position,
        .target = target,
    } });
    peer.session_state.recordSend(borrowed) catch |err| {
        peer.cancelPendingReservation(reservation);
        return err;
    };
    peer.pushPendingAssume(reservation, .{ .listener_fire = .{
        .listener_position = listener_position,
        .target = target,
    } });
}
