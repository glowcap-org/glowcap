//! Sticky terminal failure ownership and observer projection.

const foundation = @import("foundation");
const net = @import("net");
const driver_core = @import("driver_core");

const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;
const Internal = runtime.Internal;
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

/// Preserve a failure that crossed a callback or ownership-commit boundary
/// with no direct return channel. The first cause remains authoritative.
pub fn noteTerminalFailure(self: *HostRuntime, cause: anyerror) void {
    foundation.latchFailure(&self.terminal_failure, .fromError(cause));
}

pub fn noteTerminalFailureChain(self: *HostRuntime, chain: net.netlayer.ListenerCloseFailure) void {
    foundation.latchFailure(&self.terminal_failure, .fromChain(chain));
}

/// Retire one Runtime-owned core shell without turning a violated core
/// ownership precondition into process policy.
pub fn releaseCoreSession(self: *HostRuntime, session: *driver_core.HostSession) ?foundation.FailureChain {
    self.core.releaseSession(session) catch |err| return .init(err);
    return null;
}

/// Abandon a session the runtime opened but never handed out: drop its wire
/// and release the core's row, latching a release failure as terminal.
pub fn abandonFreshSession(self: *HostRuntime, session: *driver_core.HostSession) void {
    Internal.dropWire(self, session.peer_handle);
    if (releaseCoreSession(self, session)) |failure| noteTerminalFailureChain(self, failure);
}

pub fn noteTerminalOperationFailure(self: *HostRuntime, later: OperationFailure) void {
    foundation.latchFailure(&self.terminal_failure, later);
}

/// Publish a callerless failure without changing runtime control flow.
pub fn reportUnhandledFailure(self: *HostRuntime, failure: OperationFailure) void {
    if (self.opts.unhandled_failure) |observer| observer.report(observer.ctx, failure);
}

pub fn retainAndReportUnhandledFailure(self: *HostRuntime, failure: OperationFailure) void {
    noteTerminalOperationFailure(self, failure);
    reportUnhandledFailure(self, failure);
}

/// Record a provider callback contract violation at the driver boundary.
pub fn failProviderContract(self: *HostRuntime) void {
    noteTerminalFailure(self, error.ProviderContract);
}

pub fn reportObservedFailure(self: *HostRuntime, observer: anytype, tag: u64, cause: anyerror) void {
    if (self.terminal_failure != null) {
        noteTerminalFailure(self, cause);
        observer.abandoned(observer.ctx, tag);
        return;
    }
    observer.failed(observer.ctx, tag, OperationFailure.fromError(cause));
}

pub fn reportObservedOperationFailure(self: *HostRuntime, observer: anytype, tag: u64, failure: OperationFailure) void {
    if (self.terminal_failure != null) {
        noteTerminalOperationFailure(self, failure);
        observer.abandoned(observer.ctx, tag);
        return;
    }
    observer.failed(observer.ctx, tag, failure);
}

pub fn reportObservedFailureChain(
    self: *HostRuntime,
    observer: anytype,
    tag: u64,
    failure: net.netlayer.ListenFailure,
) void {
    if (self.terminal_failure != null) {
        noteTerminalOperationFailure(self, .fromChain(failure));
        observer.abandoned(observer.ctx, tag);
        return;
    }
    observer.failed(observer.ctx, tag, OperationFailure.fromChain(failure));
}

pub fn reportListenAttemptFailure(
    self: *HostRuntime,
    observer: anytype,
    tag: u64,
    attempt: *net.netlayer.ListenAttempt,
    cause: anyerror,
) void {
    var failure = net.netlayer.ListenFailure.init(cause);
    if (attempt.deinit()) |cleanup| failure.noteChain(cleanup);
    reportObservedFailureChain(self, observer, tag, failure);
}

pub fn terminalFailure(self: *const HostRuntime) ?OperationFailure {
    return self.terminal_failure;
}

pub fn operationFailure(self: *const HostRuntime, cause: anyerror) OperationFailure {
    return self.terminal_failure orelse OperationFailure.fromError(cause);
}
