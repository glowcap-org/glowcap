//! Typed Peer failure retention and phase-correct abort projection.
//!
//! The originating failure stays primary. Abort-delivery and cleanup failures
//! are bounded consequences. Deferred work projects protocol violations but
//! leaves allocator and outbound pressure retryable without blaming the peer.

const foundation = @import("foundation");

const abort_info = @import("../abort_info.zig");
const engine = @import("../mod.zig");
const inbound = @import("../inbound.zig");

const Peer = engine.Peer;

/// Project a failure that did not already cross an inbound dispatch boundary.
pub fn emitFailure(self: *Peer, err: anyerror) void {
    inbound.emitAbortForError(self, err);
}

/// Most recent typed local dispatch failure, overwritten by the next failure.
pub fn lastAbort(self: *const Peer) ?abort_info.AbortInfo {
    return self.last_abort;
}

/// Classify and retain one primary failure.
pub fn recordFailure(self: *Peer, err: anyerror) void {
    abort_info.record(&self.last_abort, err);
}

/// Retain one exact primary and its bounded cleanup consequences.
pub fn recordFailureChain(self: *Peer, chain: foundation.FailureChain) void {
    abort_info.recordChain(&self.last_abort, chain);
}

/// Attach the failure that kept a projected abort from outbound without
/// displacing the originating failure. With no origin, it becomes primary.
pub fn recordAbortDeliveryFailure(self: *Peer, err: anyerror) void {
    abort_info.recordAbortDelivery(&self.last_abort, err);
}

/// Attach a cleanup consequence without replacing the primary failure. With no
/// primary, `err` becomes it. A secondary-only diagnostic cannot be created.
pub fn recordSecondaryFailure(self: *Peer, err: anyerror) void {
    abort_info.recordSecondary(&self.last_abort, err);
}

/// Deferred work can reveal a protocol violation, but allocator and outbound
/// pressure leave the authority carrier available for retry. Classify at this
/// phase boundary instead of guessing from the error name in the step caller.
pub fn projectDeferredStepFailure(self: *Peer, err: anyerror) void {
    // A closed deferred owner already performed the one terminal projection.
    // Re-projecting here would append a second op:abort after the first.
    if (self.sessionIsClosed()) return;
    switch (err) {
        error.OutOfMemory, error.OutboundBackpressure => {},
        else => inbound.emitAbortForError(self, err),
    }
}
