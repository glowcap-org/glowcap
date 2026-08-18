//! Stable failure fact for byte carriers below transport protocol semantics.
//!
//! A carrier reports where transport establishment or byte movement failed and
//! the exact bounded causal chain. Operations and connections add lifecycle
//! identity when projecting this fact; carrier code does not own process
//! policy or a diagnostic journal.

const foundation = @import("foundation");

pub const Phase = enum(u8) {
    resolve,
    connect,
    secure_handshake,
    websocket_upgrade,
    registration,
    receive,
    transmit,
    shutdown,
};

/// Vendor-neutral detail. Zero/null means that the selected carrier cannot
/// observe the fact; adapters must not invent it.
pub const Detail = struct {
    verification_flags: u32 = 0,
    peer_alert: ?u8 = null,
    engine_code: ?i32 = null,
};

pub const Failure = struct {
    phase: Phase,
    chain: foundation.FailureChain,
    detail: Detail = .{},

    pub fn init(phase: Phase, cause: anyerror) Failure {
        return .{ .phase = phase, .chain = .init(cause) };
    }
};
