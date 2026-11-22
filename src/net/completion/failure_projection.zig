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

/// A queued connection can fail before the backend claims its socket, and
/// every backend reports that as `ConnectionAborted`. The listener then waits
/// for another arrival. Post-claim failures carry their disposition on
/// the completion. Other unclaimed refusals belong to the listener.
pub fn acceptRefusalPersists(err: anyerror) bool {
    return err != error.ConnectionAborted;
}

pub fn record(peer: anytype, comp: contract.Completion, fallback: anyerror) void {
    const chain = comp.borrowed.failureChain() orelse {
        peer.recordFailure(comp.failure orelse fallback);
        return;
    };
    peer.recordFailureChain(chain.*);
}
