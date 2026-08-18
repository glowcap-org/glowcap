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

pub fn record(peer: anytype, comp: contract.Completion, fallback: anyerror) void {
    const chain = comp.borrowed.failureChain() orelse {
        peer.recordFailure(comp.failure orelse fallback);
        return;
    };
    peer.recordFailureChain(chain.*);
}
