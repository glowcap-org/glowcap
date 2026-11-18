//! Nonblocking teardown result shared by resident connections and listeners.

const foundation = @import("foundation");
const carrier_failure = @import("../carrier_failure.zig");

/// Who receives the provider's close result. `awaited` names a caller that
/// re-asks until the outcome is `complete` or `failed`, so a resident may keep
/// the provider's handle open and publish `ev_closed` when a later call can
/// claim the result. `no_wait` names no such caller: the provider's result,
/// whenever it arrives, goes to the resident's own sink. The mode says nothing
/// about pacing. Either call may answer `pending` while admitted bytes drain,
/// and the caller asks again after the resident's next record.
pub const CloseMode = enum { no_wait, awaited };

/// One teardown attempt. `pending` means the resident retained the subject and
/// will publish its existing readiness identity when a later call can claim
/// the terminal outcome.
pub const Outcome = union(enum) {
    complete,
    pending,
    failed: carrier_failure.Report,

    /// Project a teardown at a seam that wants only the cause chain, or
    /// cannot retain a readiness owner. Pending there is a provider-contract
    /// failure, never successful cleanup.
    pub fn requireComplete(self: Outcome) ?foundation.FailureChain {
        return switch (self) {
            .complete => null,
            .pending => foundation.FailureChain.init(error.ProviderContract),
            .failed => |reported| reported.chain,
        };
    }
};
