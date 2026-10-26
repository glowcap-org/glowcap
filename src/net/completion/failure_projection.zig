//! Projection of one borrowed structured backend failure into a Peer.
//!
//! The completion owns no diagnostic storage. This helper copies the bounded
//! causal facts before the backend reclaims its borrow, while the operation's
//! control-flow error remains the compact scalar carried on the completion.

const contract = @import("contract.zig");

pub fn primary(comp: contract.Completion, fallback: anyerror) anyerror {
    if (comp.borrowed.failureChain()) |chain| return chain.cause;
    return comp.failure orelse fallback;
}

/// Whether an accept refusal outlives the arrival it was reported for. The
/// arrival itself failing (reset before accept took it, or refusing a socket
/// option) leaves the next one unaffected, so the listener accepts again.
/// Every other refusal (descriptor quota, memory, a dead listener) would
/// complete again for as long as the arrival waits, so the unknown case is
/// the persistent one.
pub fn acceptRefusalPersists(err: anyerror) bool {
    return switch (err) {
        error.ConnectionAborted, error.SocketConfigurationFailed => false,
        else => true,
    };
}

pub fn record(peer: anytype, comp: contract.Completion, fallback: anyerror) void {
    const chain = comp.borrowed.failureChain() orelse {
        peer.recordFailure(comp.failure orelse fallback);
        return;
    };
    peer.recordFailureChain(chain.*);
}
