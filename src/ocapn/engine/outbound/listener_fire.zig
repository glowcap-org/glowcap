//! Listener-fire carriers queued by the outbound path.
//!
//! A fire carrier is POD over a payload owner. Store-backed carriers retain
//! their exact answer payload box. Live-object fires rebuild `fulfill(near)`
//! from the export position.

const model = @import("model");
const session = @import("session");

const engine = @import("../mod.zig");
const Peer = engine.Peer;

const pipeline = @import("../pipeline.zig");
const resolution_chain = @import("../resolution_chain.zig");

/// A fire payload that lives in the answer store: a wire answer's or a local
/// promise projection's stored resolution, held by its exact incarnation.
pub const StoreTarget = resolution_chain.StoreTarget;

/// Which payload a listener fire borrows at encode.
pub const FireTarget = union(enum) {
    store: StoreTarget,
    near_object: model.ExportPosition,
    /// A terminal break synthesized by engine routing rather than retained in a
    /// Session store. The text is static for the carrier's whole lifetime.
    static_break: []const u8,
};

pub const Carrier = struct {
    listener_position: u64,
    target: FireTarget,
};

pub fn deinit(carrier: Carrier, peer: *Peer) void {
    peer.session_state.releaseSessionImportRetain(.from(carrier.listener_position));
    deinitEmitted(carrier, peer);
}

/// Release only the payload owner after emission. The matching listener import
/// was already transferred into an emitted `op:gc-export` (or retired locally
/// because the Session was terminal).
pub fn deinitEmitted(carrier: Carrier, peer: *Peer) void {
    switch (carrier.target) {
        .store => |store| {
            peer.session_state.releaseAnswerCarrier(store.target, store.payload);
        },
        .near_object => {},
        .static_break => {},
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
        // The carrier retains the exact payload box, so a released and reused
        // wire name neither cancels nor redirects the fire.
        .store => |store| blk: {
            const stored = peer.session_state.answerPayloadResolution(store.payload) orelse return null;
            break :blk pipeline.borrowedListenerFire(carrier.listener_position, stored.*, args);
        },
        .static_break => |message| pipeline.borrowedListenerFire(
            carrier.listener_position,
            .{ .@"break" = .{ .message = message } },
            args,
        ),
    };
}
