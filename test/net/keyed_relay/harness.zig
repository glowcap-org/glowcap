//! Shared harness for the keyed-relay proofs: the stub negotiating peer,
//! its start-session frame, and the in-process relay serve loop that parks a
//! registration and bridges one cold dial to it.

const std = @import("std");
const pancake = @import("pancake");
const netlayer_test = @import("../../support/netlayer.zig");

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const net = pancake.net;
const keyed_relay = net.relay;
const ws_relay = @import("../../support/ws_relay.zig");
const fetch_pump = @import("../../support/fetch_pump.zig");
const handshake = @import("../../support/handshake.zig");
const wait = @import("../../support/wait.zig");

const Io = std.Io;
const ip = std.Io.net;

const admission = @import("../../support/keyed_relay_admission.zig");
const AdmissionBackend = admission.AdmissionBackend;
const admissionBackend = admission.admissionBackend;
const deinitAdmissionBackend = admission.deinitAdmissionBackend;

const frame_cap = admission.frame_cap;

pub fn stubNegotiatingPeer(allocator: std.mem.Allocator) engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
}

pub fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(keyed_relay.transport_name, designator);
}

/// The registered peer: accept through the relay's ping in the parked
/// registration, then serve the bootstrap fetch. Calling `accept` directly is
/// intentional: the resident listener owns the blocking wait just like TCP.
/// The listener's owned registration task is already running before this
/// waiter starts; the relay fixture accepts that registration before the dial.
pub fn serveRegistered(
    listener: net.netlayer.Listener,
    identity: crypto.PeerKey,
    allocator: std.mem.Allocator,
) !void {
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var conn = try listener.accept(&peer, .{ .read = read_buf, .write = write_buf });
    defer conn.deinit();

    const hex = identity.toDesignator();
    try peer.sendCopying(startSession(hex[0..]));

    while (true) {
        const progress = conn.pump() catch |err| switch (err) {
            error.ConnectionLost, error.TruncatedFrame => break,
            else => return err,
        };
        if (progress == .closed) break;
    }
}
