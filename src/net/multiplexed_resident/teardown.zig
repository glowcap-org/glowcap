//! Nonblocking teardown result shared by resident connections and listeners.

const foundation = @import("foundation");

/// One teardown attempt. `pending` means the resident retained the subject and
/// will publish its existing readiness identity when a later call can claim
/// the terminal outcome.
pub const Outcome = union(enum) {
    complete,
    pending,
    failed: foundation.FailureChain,

    /// Project a teardown at a seam that cannot retain a readiness owner.
    /// Pending there is a provider-contract failure, never successful cleanup.
    pub fn requireComplete(self: Outcome) ?foundation.FailureChain {
        return switch (self) {
            .complete => null,
            .pending => foundation.FailureChain.init(error.ProviderContract),
            .failed => |reported| reported,
        };
    }
};
