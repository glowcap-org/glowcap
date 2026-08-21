//! Listener-fire carriers queued by the outbound path.
//!
//! A fire carrier is POD over a payload owner. Answer-backed carriers retain
//! their exact answer payload box; imported-promise carriers carry a row stamp;
//! live-object fires rebuild `fulfill(near)` from the export position.

const model = @import("model");
const session = @import("session");

const engine = @import("../mod.zig");
const Peer = engine.Peer;

const pipeline = @import("../pipeline.zig");

/// A fire payload that lives in a store: an inbound answer's stored
/// resolution, or a handoff-imported third-party promise's stored resolution
/// (ADR-0009). The two share the promise cell shape, keyed on distinct wire
/// position spaces, so one lookup serves both.
pub const StoreTarget = union(enum) {
    answer: struct {
        target: session.AnswerTarget,
        payload: *session.AnswerPayload,
    },
    import: struct { position: model.ImportPosition, row_id: u64 },
};

/// Which payload a listener fire borrows at encode.
pub const FireTarget = union(enum) {
    store: StoreTarget,
    near_object: model.ExportPosition,
};

pub const Carrier = struct {
    listener_position: u64,
    target: FireTarget,
};

pub fn deinit(carrier: Carrier, peer: *Peer) void {
    switch (carrier.target) {
        .store => |target| switch (target) {
            .answer => |answer| {
                peer.session_state.retireDetachedAnswer(answer.target, answer.payload);
                peer.session_state.releaseAnswerPayload(answer.payload);
            },
            .import => {},
        },
        .near_object => {},
    }
}

pub fn borrowedMessage(peer: *Peer, carrier: Carrier, args: *[2]model.Argument) ?model.Message {
    return switch (carrier.target) {
        .near_object => |export_position| blk: {
            const slot = peer.session_state.exportSlot(export_position) orelse return null;
            if (slot != .local_value) return null;
            const resolution: model.Resolution = .{ .fulfill = .{
                .reference = .{ .near = model.NearRef.object(export_position.int()) },
            } };
            break :blk pipeline.borrowedListenerFire(carrier.listener_position, resolution, args);
        },
        .store => |store_target| blk: {
            const stored = resolveStoreChecked(peer, store_target) orelse return null;
            break :blk pipeline.borrowedListenerFire(carrier.listener_position, stored.*, args);
        },
    };
}

fn resolveFireStore(peer: *Peer, target: StoreTarget) ?struct {
    row_id: u64,
    resolution: *const model.Resolution,
} {
    switch (target) {
        .answer => |answer| {
            const resolution = peer.session_state.answerPayloadResolution(answer.payload) orelse return null;
            return .{ .row_id = answer.target.row_id, .resolution = resolution };
        },
        .import => |import| {
            const row = peer.session_state.findImportedPromise(import.position) orelse return null;
            if (row.cell.resolution) |*resolution| return .{ .row_id = row.cell.row_id, .resolution = resolution };
            return null;
        },
    }
}

/// The borrowed stored resolution behind `target`.
///
/// Answer carriers own a retained pointer to the exact incarnation and survive
/// name reuse. Imported-promise carriers validate the current row stamp. The
/// returned resolution borrows the store and is valid only until that store is
/// next mutated.
pub fn resolveStoreChecked(peer: *Peer, target: StoreTarget) ?*const model.Resolution {
    if (target == .answer) return peer.session_state.answerPayloadResolution(target.answer.payload);
    const found = resolveFireStore(peer, target) orelse return null;
    const stamped = switch (target) {
        .answer => unreachable,
        .import => |import| import.row_id,
    };
    if (found.row_id != stamped) return null;
    return found.resolution;
}
