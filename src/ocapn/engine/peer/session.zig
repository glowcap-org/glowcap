//! Peer-facing Session lifecycle, profile, and partner-session projection.
//!
//! Session remains authoritative. This module owns the engine boundary that
//! closes it, selects the pre-open versus settled inbound profile, and exposes
//! borrowed facts learned from the partner handshake.

const std = @import("std");
const model = @import("model");
const session = @import("session");

const engine = @import("../mod.zig");
const lifecycle = @import("lifecycle.zig");

const Peer = engine.Peer;

/// Whether the start-session handshake is complete and traffic is admitted.
pub fn isOpen(self: *const Peer) bool {
    return self.session_state.state == .open;
}

/// Whether CapTP authority is terminal while an adapter may still retain the
/// shell to drain its final transport work.
pub fn isClosed(self: *const Peer) bool {
    return self.session_state.state == .closed;
}

/// Retire all CapTP handoff authority at the close transition, even when an
/// embedder retains the Peer shell to drain its final abort frame.
pub fn retireClosedAuthority(self: *Peer) void {
    std.debug.assert(self.session_state.state == .closed);
    lifecycle.clearPendingWithdraws(self);
    lifecycle.retireGiftRegistry(self);
    if (self.node_services) |services| services.sessionClosed();
}

pub fn close(self: *Peer) void {
    if (self.session_state.state == .closed) return;
    self.session_state.close();
    retireClosedAuthority(self);
}

/// Session resource bounds, fixed at construction.
pub fn limits(self: *const Peer) session.SessionLimits {
    return self.session_state.limits;
}

/// Codec the session speaks on the wire, fixed or settled by negotiation.
pub fn codecId(self: *const Peer) model.CodecId {
    return self.session_state.codec;
}

/// Codec of an arriving frame. A handshake cannot be encoded in the result of
/// its own negotiation, so negotiating traffic stays on the Syrup baseline.
pub fn inboundCodec(self: *const Peer) model.CodecId {
    return switch (self.session_state.state) {
        .negotiating => .syrup,
        .open, .closed => self.session_state.codec,
    };
}

/// CapTP profile admitting an arriving frame. Retained events carry this exact
/// value so later projection uses the same profile that admitted the frame.
pub fn inboundProfile(self: *const Peer) model.CaptpVersion {
    return switch (self.session_state.state) {
        .negotiating => model.Preference.baseline.captp_version,
        .open, .closed => self.session_state.captp_version,
    };
}

/// Partner session key learned from `op:start-session`, borrowed until teardown.
pub fn partnerSessionKey(self: *const Peer) ?[]const u8 {
    return self.session_state.partnerSessionKey();
}

/// Verbatim partner locator record from `op:start-session`, borrowed until
/// teardown and used as the handoff exporter-location signing value.
pub fn partnerLocatorRaw(self: *const Peer) ?[]const u8 {
    return self.session_state.partnerLocatorRaw();
}
