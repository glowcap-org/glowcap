//! Dial continuity above the completion loop (ADR-0082).
//!
//! `DialPolicy` owns dial policy and `isTransient` classifies
//! `net.netlayer.DialError` into transient vs permanent. Retry only ever
//! applies to transient faults, and never pretends Peer tables survive a
//! rebuild: each successful dial is a new CapTP session the caller must
//! adopt. The `HostRuntime` pump executes the policy on its staged-dial
//! rows (ADR-0193). Discovery dial budgets across bindings share the
//! `driver_core` defaults this policy projects.

const driver_core = @import("driver_core");
const net = @import("net");

const DialError = net.netlayer.DialError;

/// Shared discovery-posture dial defaults. The runtime executes the retry.
pub const discovery_retry_ms: u64 = driver_core.discovery_retry_ms;
pub const discovery_max_attempts: u32 = driver_core.discovery_max_attempts;

/// Caller-supplied dial policy. Defaults match the discovery budget.
pub const DialPolicy = struct {
    /// Attempts including the first dial. Must be at least 1.
    max_attempts: u32 = discovery_max_attempts,
    /// How long a transiently failed dial parks before the next attempt.
    retry_interval_ms: u64 = discovery_retry_ms,

    pub fn discovery() DialPolicy {
        return .{};
    }
};

/// Whether a dial fault is worth retrying under ADR-0081/0082.
/// `InvalidAddress` and `ConnectionRefused` are permanent configuration or
/// peer-refusal faults. `OutOfMemory` is not a network transient.
pub fn isTransient(err: DialError) bool {
    return switch (err) {
        error.NetworkUnreachable, error.TimedOut, error.ConnectionLost, error.WouldBlock => true,
        error.InvalidAddress,
        error.InvalidOptions,
        error.ConnectionRefused,
        error.SocketConfigurationFailed,
        error.WakeNudgeFailed,
        error.OutOfMemory,
        => false,
    };
}

/// Continuity core: policy plus dial-retry. Not a Session facade.
pub const DialOutcome = enum {
    /// Dial succeeded. Caller owns a new session identity.
    ok,
    /// Transient fault. The open parks for the interval, then dials again.
    transient_retry,
    /// Permanent DialError, never retried.
    permanent,
    /// Attempt budget exhausted on transient faults.
    exhausted,
};

/// Optional embedder metric recipient (ADR-0082 Track C): one `report` per
/// dial attempt outcome, with `attempt` 1-based. The `HostRuntime` dial-retry
/// seam reports through it.
pub const DialOutcomeObserver = struct {
    ctx: *anyopaque,
    report: *const fn (ctx: *anyopaque, outcome: DialOutcome, attempt: u32) void,
};
