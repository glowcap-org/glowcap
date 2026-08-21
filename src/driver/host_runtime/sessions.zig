//! Application session-handle and exporter-session ownership.

const std = @import("std");

const engine = @import("engine");
const driver_core = @import("driver_core");

const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;
const Internal = runtime.Internal;
const Error = driver_core.Error;
const AdmissionError = Error || error{ProviderContract};

/// Release one session and its wire: outbound the core already queued for it
/// is written first (a condemned session's abort must reach the partner). A
/// transport refusal closes the wire through the ordinary observable failure
/// path; post-commit core failures become the Runtime's sticky terminal cause.
/// The core then breaks its vows and fail-closes sibling answers before the
/// transport is released.
pub fn releaseWire(self: *HostRuntime, session: *driver_core.HostSession) !void {
    self.enterDriver();
    defer self.leaveDriver();

    try releaseWireOwned(self, session);
}

pub fn releaseWireOwned(self: *HostRuntime, session: *driver_core.HostSession) !void {
    try self.refuseReentry();
    if (session.host != self.core) return Error.SessionNotOwned;
    const wire = self.wires.get(session.peer_handle) orelse return Error.SessionNotOwned;
    if (wire.session != session) return Error.SessionNotOwned;
    const peer_handle = session.peer_handle;
    const claimed = wire.session_handle_claimed;
    if (!wire.closed) {
        Internal.writeOutbound(self, wire) catch |err| Internal.closeWire(self, wire, err);
        if (!wire.closed) Internal.closeWire(self, wire, null);
    }
    // `releaseSession` has only pre-commit failure edges. Cross it before
    // consuming the wire so an error always leaves the caller's handle
    // retryable; everything below is the one-way ownership commit.
    try self.core.releaseSession(session);
    Internal.dropWire(self, peer_handle);
    if (claimed) {
        std.debug.assert(self.claimed_session_handles != 0);
        self.claimed_session_handles -= 1;
    }
    self.drainActions() catch |err| Internal.noteTerminalFailure(self, err);
    // Retirement remains runtime work after this handle is consumed. A
    // refusal becomes sticky terminal state rather than an error that invites
    // the caller to reuse a freed session pointer.
    if (self.retiring and self.claimed_session_handles == 0)
        Internal.progressRetirement(self) catch |err| Internal.noteTerminalFailure(self, err);
}

/// Claim the one owning `driver.Session` handle permitted for a wire.
/// Allocation happens before this call, so a successful claim never needs
/// rollback and duplicate release authority is unrepresentable.
pub fn claimSessionHandle(self: *HostRuntime, session: *driver_core.HostSession) Error!void {
    self.enterDriver();
    defer self.leaveDriver();
    try claimSessionHandleOwned(self, session);
}

fn claimSessionHandleOwned(self: *HostRuntime, session: *driver_core.HostSession) Error!void {
    const wire = self.wires.get(session.peer_handle) orelse return Error.SessionNotOwned;
    if (wire.session != session) return Error.SessionNotOwned;
    if (wire.session_handle_claimed) return Error.SessionAlreadyOwned;
    wire.session_handle_claimed = true;
    self.claimed_session_handles += 1;
}

/// Resolve the live exporter session named by one opaque Host capability and
/// ensure the Runtime's single application handle owns it. Repeated exposure
/// is idempotent; a previously internal redeem wire is admitted as application
/// work and claimed before its pointer crosses an adapter.
pub fn claimReferenceExporter(self: *HostRuntime, raw_ref: u64) AdmissionError!?*driver_core.HostSession {
    self.enterDriver();
    defer self.leaveDriver();

    const session = self.core.capabilitySession(self.core.capabilityFromRaw(raw_ref)) orelse return null;
    const wire = self.wires.get(session.peer_handle) orelse return null;
    if (wire.session != session) return null;
    if (!wire.session_handle_claimed) {
        try Internal.admitApplicationOperation(self);
        try claimSessionHandleOwned(self, session);
    }
    return session;
}

/// Whether this runtime still owns the exact session shell named by a queued
/// adapter event. The peer handle is carried separately so a stale event never
/// dereferences a shell already released by the application.
pub fn sessionEventIsLive(
    self: *const HostRuntime,
    peer_handle: engine.PeerHandle,
    session: *const driver_core.HostSession,
) bool {
    const wire = self.wires.get(peer_handle) orelse return false;
    return wire.session == session;
}
