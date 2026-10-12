//! Dial continuity above the completion loop (ADR-0082).
//!
//! `DialRetry` owns dial policy and classifies `net.netlayer.DialError`
//! into transient vs permanent. It retries only transient faults and never
//! pretends Peer tables survive a rebuild: each successful dial is a new
//! CapTP session the caller must adopt. Discovery dial budgets across
//! bindings and the Zig reachability driver share the `driver_core` defaults
//! this executor projects.

const std = @import("std");
const driver_core = @import("driver_core");
const net = @import("net");

const DialError = net.netlayer.DialError;

/// Shared discovery-posture dial defaults. Retry execution stays in `driver`.
pub const discovery_retry_ms: u64 = driver_core.discovery_retry_ms;
pub const discovery_max_attempts: u32 = driver_core.discovery_max_attempts;

/// Caller-supplied dial policy. Defaults match the discovery budget.
pub const DialPolicy = struct {
    /// Attempts including the first dial. Must be at least 1.
    max_attempts: u32 = discovery_max_attempts,
    /// Sleep between a failed transient dial and the next attempt.
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
    /// Transient fault, another attempt will run after sleep.
    transient_retry,
    /// Permanent DialError, never retried.
    permanent,
    /// Attempt budget exhausted on transient faults.
    exhausted,
};

/// Optional embedder metric hook (ADR-0082 Track C): one call per dial attempt
/// outcome. `attempt` is 1-based.
pub const OnDialOutcome = *const fn (ctx: ?*anyopaque, outcome: DialOutcome, attempt: u32) void;

pub const DialRetry = struct {
    policy: DialPolicy = .{},
    on_dial_outcome: ?OnDialOutcome = null,
    outcome_ctx: ?*anyopaque = null,

    pub fn init(policy: DialPolicy) DialRetry {
        return .{ .policy = policy };
    }

    pub fn discovery() DialRetry {
        return .{ .policy = DialPolicy.discovery() };
    }

    fn report(self: DialRetry, outcome: DialOutcome, attempt: u32) void {
        if (self.on_dial_outcome) |hook| hook(self.outcome_ctx, outcome, attempt);
    }

    /// Run `attempt_dial` until it succeeds, a permanent DialError surfaces, or the
    /// attempt budget is exhausted. `sleep_ms` is invoked between transient
    /// failures (bindings pass their language sleep, Zig tests may no-op).
    ///
    /// On success the caller owns a **new** session over a new connection, never the
    /// previous Peer tables.
    pub fn dial(
        self: DialRetry,
        comptime T: type,
        attempt_dial: *const fn (ctx: ?*anyopaque) DialError!T,
        ctx: ?*anyopaque,
        sleep_ms: *const fn (ms: u64) void,
    ) DialError!T {
        const max = @max(self.policy.max_attempts, 1);
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            if (attempt_dial(ctx)) |ok| {
                self.report(.ok, attempt);
                return ok;
            } else |err| {
                if (!isTransient(err)) {
                    self.report(.permanent, attempt);
                    return err;
                }
                if (attempt >= max) {
                    self.report(.exhausted, attempt);
                    return err;
                }
                self.report(.transient_retry, attempt);
                sleep_ms(self.policy.retry_interval_ms);
            }
        }
    }
};
