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
const Peer = engine.Peer;
const ListenerDrainAction = resolution_math.ListenerDrainAction;
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
    if (peer.session_state.importedPromiseResolution(import_position)) |resolution| {
        const row = peer.session_state.findImportedPromise(import_position).?;
        try enqueueFire(
            peer,
            listener_entry.listener.import_position.int(),
            .{ .store = .{ .import = .{ .position = import_position, .row_id = row.cell.row_id } } },
            resolution.*,
        );
    } else {
        try peer.session_state.installImportedPromiseListener(import_position, listener_entry);
    }
}

fn installAnswerListener(peer: *Peer, answer: model.AnswerName, listen: model.view.Listen) !void {
    const listener_entry = try listenerEntryFromListen(peer, listen);
    if (peer.session_state.peekResolutionNamed(answer)) |resolution| {
        const row_id = peer.session_state.inboundAnswerRowIdNamed(answer).?;
        try applyListenerDrain(
            peer,
            .{ .answer = .{ .position = answer, .row_id = row_id } },
            resolution.*,
            classifyListenerDrain(listener_entry, resolution.*),
        );
    } else {
        try peer.session_state.installListenerNamed(answer, listener_entry);
    }
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
    const position = listen.listener.position() orelse return session.Error.InvalidReference;
    try peer.session_state.registerImport(model.ImportPosition.from(position));
    const resolution: model.Resolution = .{ .fulfill = .{
        .reference = .{ .near = model.NearRef.object(export_position.int()) },
    } };
    try enqueueFire(peer, position, .{ .near_object = export_position }, resolution);
}

pub fn fireListenersOnAnswer(peer: *Peer, answer: model.AnswerName, resolution: model.Resolution) !void {
    const row_id = peer.session_state.inboundAnswerRowIdNamed(answer) orelse return;
    const listeners = try peer.session_state.takePipelinedListenersNamed(answer);
    defer peer.allocator.free(listeners);

    for (listeners) |entry| {
        try applyListenerDrain(
            peer,
            .{ .answer = .{ .position = answer, .row_id = row_id } },
            resolution,
            classifyListenerDrain(entry, resolution),
        );
    }
}

pub fn fireImportedPromiseListeners(peer: *Peer, import_position: model.ImportPosition) !void {
    const row = peer.session_state.findImportedPromise(import_position) orelse return;
    const resolution = row.cell.resolution orelse return;
    var prepared = try prepareImportedPromiseFires(peer, import_position, row.cell.row_id, resolution);
    prepared.commit(peer, import_position, row.cell.row_id, resolution);
}

pub const PreparedImportedFires = struct {
    listeners: []session.ListenerEntry,
    reservation: ?Peer.PendingReservation = null,
    reserved: usize = 0,

    pub fn abandon(self: *PreparedImportedFires, peer: *Peer, import_position: model.ImportPosition) void {
        if (self.reservation) |reservation| {
            for (0..self.reserved) |_| peer.cancelPendingReservation(reservation);
        }
        peer.session_state.restoreImportedPromiseListeners(import_position, self.listeners);
        self.* = .{ .listeners = &.{} };
    }

    pub fn commit(
        self: *PreparedImportedFires,
        peer: *Peer,
        import_position: model.ImportPosition,
        row_id: u64,
        resolution: model.Resolution,
    ) void {
        for (self.listeners) |entry| {
            var args: [2]model.Argument = undefined;
            const message = borrowedListenerFire(entry.listener.import_position.int(), resolution, &args);
            peer.session_state.commitPreparedListenerFire(message);
            peer.pushPendingAssume(self.reservation.?, .{ .listener_fire = .{
                .listener_position = entry.listener.import_position.int(),
                .target = .{ .store = .{ .import = .{
                    .position = import_position,
                    .row_id = row_id,
                } } },
            } });
        }
        if (self.listeners.len != 0) peer.allocator.free(self.listeners);
        self.* = .{ .listeners = &.{} };
    }
};

pub fn prepareImportedPromiseFires(
    peer: *Peer,
    import_position: model.ImportPosition,
    row_id: u64,
    resolution: model.Resolution,
) !PreparedImportedFires {
    var prepared: PreparedImportedFires = .{
        .listeners = try peer.session_state.takeImportedPromiseListeners(import_position),
    };
    errdefer prepared.abandon(peer, import_position);
    if (prepared.listeners.len == 0) return prepared;

    for (prepared.listeners) |entry|
        try peer.session_state.validateListenerFireTarget(entry.listener);
    try peer.session_state.ensureSentResolutionExportCapacity(resolution);

    var batch = try peer.beginPendingBatch(prepared.listeners.len);
    for (prepared.listeners) |entry| {
        const reservation = try batch.reserve(.{ .listener_fire = .{
            .listener_position = entry.listener.import_position.int(),
            .target = .{ .store = .{ .import = .{
                .position = import_position,
                .row_id = row_id,
            } } },
        } });
        if (prepared.reservation) |first|
            std.debug.assert(first.charge == reservation.charge)
        else
            prepared.reservation = reservation;
        prepared.reserved += 1;
    }
    return prepared;
}

fn enqueueFire(
    peer: *Peer,
    listener_position: u64,
    target: engine.FireTarget,
    resolution: model.Resolution,
) !void {
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

fn applyListenerDrain(
    peer: *Peer,
    target: engine.StoreTarget,
    resolution: model.Resolution,
    action: ListenerDrainAction,
) !void {
    switch (action) {
        .fire => |position| try enqueueDrainFire(peer, position, target, resolution),
        .reinstall => |reinstall| try peer.session_state.installListener(reinstall.next_answer, reinstall.entry),
        .discard => {},
    }
}

fn enqueueDrainFire(
    peer: *Peer,
    listener_position: u64,
    target: engine.StoreTarget,
    resolution: model.Resolution,
) !void {
    const stamped: engine.StoreTarget = switch (target) {
        .answer => |answer| .{ .answer = .{
            .position = answer.position,
            .row_id = peer.session_state.inboundAnswerRowIdNamed(answer.position) orelse return,
        } },
        .import => target,
    };
    try enqueueFire(peer, listener_position, .{ .store = stamped }, resolution);
}
