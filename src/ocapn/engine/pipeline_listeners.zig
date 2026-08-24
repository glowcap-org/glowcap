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
const classifyListenerDrain = resolution_math.classifyListenerDrain;

const InboundListenClass = union(enum) {
    answer: model.AnswerName,
    third_party_import: model.ImportPosition,
    live_export: model.ExportPosition,
};

fn classifyInboundListenTarget(peer: *Peer, listen: model.view.Listen) InboundListenClass {
    switch (listen.target) {
        .promise => |promise| return .{ .answer = .fromWire(promise.answer_position) },
        .near => |near| {
            const as_import = model.ImportPosition.from(near.export_position.int());
            if (peer.session_state.isThirdPartyImport(as_import))
                return .{ .third_party_import = as_import };
            if (peer.session_state.exportSlot(near.export_position)) |export_slot| {
                if (export_slot == .local_unresolved) if (peer.session_state.answerForLocalPromiseExport(near.export_position)) |answer|
                    return .{ .answer = answer };
            }
            return .{ .live_export = near.export_position };
        },
        .far, .routed, .sturdy, .broken => unreachable,
    }
}

pub fn maybeInstallInboundListener(peer: *Peer, listen: model.view.Listen) !void {
    try peer.session_state.validateInboundListen(listen);
    switch (classifyInboundListenTarget(peer, listen)) {
        .answer => |answer| try installAnswerListener(peer, answer, listen),
        .third_party_import => |import_position| try installThirdPartyImportListener(peer, import_position, listen),
        .live_export => |export_position| try installExportListener(peer, export_position, listen),
    }
}

fn listenerEntryFromListen(peer: *Peer, listen: model.view.Listen) !session.ListenerEntry {
    const position = listen.listener.position() orelse return session.Error.InvalidReference;
    try peer.session_state.registerImport(model.ImportPosition.from(position));
    return .{ .listener = model.FarRef.object(position), .mode = listen.mode };
}

fn installThirdPartyImportListener(peer: *Peer, import_position: model.ImportPosition, listen: model.view.Listen) !void {
    const listener_entry = try listenerEntryFromListen(peer, listen);
    var retain_live = true;
    errdefer if (retain_live)
        peer.session_state.releaseImportRetain(listener_entry.listener.import_position);
    if (peer.session_state.importedPromiseStoredResolution(import_position)) |resolution| {
        const row = peer.session_state.findImportedPromise(import_position).?;
        try applyStoredListener(
            peer,
            .{
                .target = .{ .import = .{ .position = import_position, .row_id = row.cell.row_id } },
                .stored = resolution,
            },
            listener_entry,
        );
    } else {
        try peer.session_state.installImportedPromiseListener(import_position, listener_entry);
    }
    retain_live = false;
}

fn installAnswerListener(peer: *Peer, answer: model.AnswerName, listen: model.view.Listen) !void {
    const listener_entry = try listenerEntryFromListen(peer, listen);
    var retain_live = true;
    errdefer if (retain_live)
        peer.session_state.releaseImportRetain(listener_entry.listener.import_position);
    if (peer.session_state.peekStoredResolutionNamed(answer)) |resolution| {
        const target = peer.session_state.answerTargetNamed(answer) orelse return session.Error.InvalidReference;
        const payload = peer.session_state.answerPayloadForTarget(target) orelse return session.Error.InvalidReference;
        try applyStoredListener(
            peer,
            .{
                .target = .{ .answer = .{ .target = target, .payload = payload } },
                .stored = resolution,
            },
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
    return session.Error.InvalidReference;
}

fn fireLiveObjectExportListener(peer: *Peer, export_position: model.ExportPosition, listen: model.view.Listen) !void {
    const listener_entry = try listenerEntryFromListen(peer, listen);
    var retain_live = true;
    errdefer if (retain_live)
        peer.session_state.releaseImportRetain(listener_entry.listener.import_position);
    const resolution: model.Resolution = .{ .fulfill = .{
        .reference = .{ .near = model.NearRef.object(export_position.int()) },
    } };
    switch (classifyListenerDrain(listener_entry, resolution)) {
        .fire => |position| try enqueueFire(peer, position, .{ .near_object = export_position }, resolution),
        .discard => peer.session_state.releaseImportRetain(listener_entry.listener.import_position),
        .reinstall => unreachable,
    }
    retain_live = false;
}

pub fn prepareAnswerListenerDrain(
    peer: *Peer,
    payload: *session.AnswerPayload,
    outcome: ?resolution_chain.Outcome,
) !PreparedListenerDrain {
    const listeners = try peer.session_state.takeAnswerPayloadListeners(payload);
    return prepareListenerDrainPlan(
        peer,
        .{ .answer = payload },
        listeners,
        if (listeners.len == 0)
            .{ .terminal_break = "" }
        else
            listenerDrainPlan(outcome orelse unreachable),
    );
}

const ListenerSource = union(enum) {
    answer: *session.AnswerPayload,
    import: model.ImportPosition,

    fn restore(self: ListenerSource, peer: *Peer, listeners: []session.ListenerEntry) void {
        switch (self) {
            .answer => |payload| peer.session_state.restoreAnswerPayloadListeners(payload, listeners),
            .import => |position| peer.session_state.restoreImportedPromiseListeners(position, listeners),
        }
    }
};

const ListenerDrainPlan = union(enum) {
    terminal_break: []const u8,
    reinstall: session.AnswerTarget,
    drain: struct {
        target: engine.StoreTarget,
        resolution: model.Resolution,
    },
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
        .terminal_break => |message| switch (classifyListenerDrain(entry, terminalBreak(message))) {
            .fire => |position| try enqueueFire(
                peer,
                position,
                .{ .static_break = message },
                terminalBreak(message),
            ),
            .discard => peer.session_state.releaseImportRetain(entry.listener.import_position),
            .reinstall => unreachable,
        },
        .reinstall => |target| {
            var prepared = try peer.session_state.prepareListenerBatchTarget(target, 1);
            errdefer prepared.abandon(&peer.session_state);
            prepared.commit(&.{entry});
        },
        .drain => |stored| switch (classifyListenerDrain(entry, stored.resolution)) {
            .fire => |position| try enqueueFire(
                peer,
                position,
                .{ .store = stored.target },
                stored.resolution,
            ),
            .discard => peer.session_state.releaseImportRetain(entry.listener.import_position),
            .reinstall => unreachable,
        },
    }
}

pub const PreparedListenerDrain = struct {
    source: ListenerSource,
    listeners: []session.ListenerEntry,
    plan: ListenerDrainPlan,
    reservation: ?Peer.PendingReservation = null,
    reserved: usize = 0,
    target_retains: usize = 0,
    reinstall_prepared: ?session.Session.PreparedListenerBatch = null,

    pub fn abandon(self: *PreparedListenerDrain, peer: *Peer) void {
        const source = self.source;
        if (self.reservation) |reservation| {
            for (0..self.reserved) |_| peer.cancelPendingReservation(reservation);
        }
        if (self.target_retains != 0) {
            std.debug.assert(self.plan == .drain);
            for (0..self.target_retains) |_|
                releaseFireTarget(peer, self.plan.drain.target);
        }
        if (self.reinstall_prepared) |*prepared| prepared.abandon(&peer.session_state);
        source.restore(peer, self.listeners);
        self.* = .{ .source = source, .listeners = &.{}, .plan = .{ .terminal_break = "" } };
    }

    pub fn commit(self: *PreparedListenerDrain, peer: *Peer) void {
        if (self.listeners.len == 0) {
            self.* = undefined;
            return;
        }
        switch (self.plan) {
            .terminal_break => |reason| for (self.listeners) |entry| switch (classifyListenerDrain(entry, terminalBreak(reason))) {
                .fire => |position| {
                    var args: [2]model.Argument = undefined;
                    const message = borrowedListenerFire(position, terminalBreak(reason), &args);
                    peer.session_state.commitPreparedListenerFire(message);
                    peer.pushPendingAssume(self.reservation.?, .{ .listener_fire = .{
                        .listener_position = position,
                        .target = .{ .static_break = reason },
                    } });
                },
                .discard => peer.session_state.releaseImportRetain(entry.listener.import_position),
                .reinstall => unreachable,
            },
            .reinstall => self.reinstall_prepared.?.commit(self.listeners),
            .drain => |stored| for (self.listeners) |entry| {
                switch (classifyListenerDrain(entry, stored.resolution)) {
                    .fire => |position| {
                        var args: [2]model.Argument = undefined;
                        const message = borrowedListenerFire(position, stored.resolution, &args);
                        peer.session_state.commitPreparedListenerFire(message);
                        peer.pushPendingAssume(self.reservation.?, .{ .listener_fire = .{
                            .listener_position = position,
                            .target = .{ .store = stored.target },
                        } });
                    },
                    .discard => peer.session_state.releaseImportRetain(entry.listener.import_position),
                    .reinstall => unreachable,
                }
            },
        }
        if (self.listeners.len != 0) peer.allocator.free(self.listeners);
        self.* = undefined;
    }
};

fn retainFireTarget(peer: *Peer, target: engine.StoreTarget) !void {
    switch (target) {
        .answer => |answer| try peer.session_state.retainAnswerPayload(answer.payload),
        .import => {},
    }
}

fn releaseFireTarget(peer: *Peer, target: engine.StoreTarget) void {
    switch (target) {
        .answer => |answer| peer.session_state.releaseAnswerPayload(answer.payload),
        .import => {},
    }
}

fn prepareListenerDrainPlan(
    peer: *Peer,
    source: ListenerSource,
    listeners: []session.ListenerEntry,
    plan: ListenerDrainPlan,
) !PreparedListenerDrain {
    var prepared = PreparedListenerDrain{ .source = source, .listeners = listeners, .plan = plan };
    errdefer prepared.abandon(peer);
    if (prepared.listeners.len == 0) return prepared;
    switch (prepared.plan) {
        .terminal_break => |reason| {
            var fire_count: usize = 0;
            for (prepared.listeners) |entry| switch (classifyListenerDrain(entry, terminalBreak(reason))) {
                .fire => {
                    try peer.session_state.validateListenerFireTarget(entry.listener);
                    fire_count += 1;
                },
                .discard => {},
                .reinstall => unreachable,
            };
            if (fire_count == 0) return prepared;
            var batch = try peer.beginPendingBatch(fire_count);
            for (prepared.listeners) |entry| switch (classifyListenerDrain(entry, terminalBreak(reason))) {
                .fire => |position| {
                    const reservation = try batch.reserve(.{ .listener_fire = .{
                        .listener_position = position,
                        .target = .{ .static_break = reason },
                    } });
                    if (prepared.reservation) |first_reservation|
                        std.debug.assert(first_reservation.charge == reservation.charge)
                    else
                        prepared.reservation = reservation;
                    prepared.reserved += 1;
                },
                .discard => {},
                .reinstall => unreachable,
            };
        },
        .reinstall => |next_target| prepared.reinstall_prepared =
            try peer.session_state.prepareListenerBatchTarget(next_target, prepared.listeners.len),
        .drain => |stored| {
            var fire_count: usize = 0;
            for (prepared.listeners) |entry| switch (classifyListenerDrain(entry, stored.resolution)) {
                .fire => {
                    try peer.session_state.validateListenerFireTarget(entry.listener);
                    fire_count += 1;
                },
                .discard => {},
                .reinstall => unreachable,
            };
            if (fire_count == 0) return prepared;
            try peer.session_state.ensureSentResolutionExportCapacity(stored.resolution);
            var batch = try peer.beginPendingBatch(fire_count);
            for (prepared.listeners) |entry| switch (classifyListenerDrain(entry, stored.resolution)) {
                .fire => |position| {
                    try retainFireTarget(peer, stored.target);
                    prepared.target_retains += 1;
                    const reservation = try batch.reserve(.{ .listener_fire = .{
                        .listener_position = position,
                        .target = .{ .store = stored.target },
                    } });
                    if (prepared.reservation) |first_reservation|
                        std.debug.assert(first_reservation.charge == reservation.charge)
                    else
                        prepared.reservation = reservation;
                    prepared.reserved += 1;
                },
                .discard => {},
                .reinstall => unreachable,
            };
        },
    }
    return prepared;
}

fn listenerDrainPlan(outcome: resolution_chain.Outcome) ListenerDrainPlan {
    return switch (outcome) {
        .terminal => |terminal| .{ .drain = .{
            .target = terminal.target,
            .resolution = terminal.resolution,
        } },
        .pending => |target| .{ .reinstall = target },
        .terminal_break => |message| .{ .terminal_break = message },
    };
}

pub fn fireImportedPromiseListeners(peer: *Peer, import_position: model.ImportPosition) !void {
    const row = peer.session_state.findImportedPromise(import_position) orelse return;
    const resolution = if (row.cell.resolution) |*stored| stored else return;
    var prepared = try prepareListenerDrainPlan(
        peer,
        .{ .import = import_position },
        try peer.session_state.takeImportedPromiseListeners(import_position),
        listenerDrainPlan(resolution_chain.follow(peer, .{
            .target = .{ .import = .{ .position = import_position, .row_id = row.cell.row_id } },
            .stored = resolution,
        })),
    );
    prepared.commit(peer);
}

pub fn prepareImportedPromiseFires(
    peer: *Peer,
    import_position: model.ImportPosition,
    row_id: u64,
    resolution: model.Resolution,
) !PreparedListenerDrain {
    const stored: session.StoredResolution = .{
        .value = resolution,
        .promise_target = try peer.session_state.promiseTargetForResolution(resolution),
    };
    return prepareListenerDrainPlan(
        peer,
        .{ .import = import_position },
        try peer.session_state.takeImportedPromiseListeners(import_position),
        listenerDrainPlan(resolution_chain.follow(peer, .{
            .target = .{ .import = .{ .position = import_position, .row_id = row_id } },
            .stored = &stored,
        })),
    );
}

fn enqueueFire(
    peer: *Peer,
    listener_position: u64,
    target: engine.FireTarget,
    resolution: model.Resolution,
) !void {
    const answer_payload: ?*session.AnswerPayload = switch (target) {
        .store => |store| switch (store) {
            .answer => |answer| answer.payload,
            .import => null,
        },
        .near_object => null,
        .static_break => null,
    };
    if (answer_payload) |payload|
        try peer.session_state.retainAnswerPayload(payload);
    errdefer if (answer_payload) |payload|
        peer.session_state.releaseAnswerPayload(payload);
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
