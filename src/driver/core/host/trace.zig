//! Host-owned trace emission.
//!
//! `../trace.zig` owns the callback vocabulary. This leaf owns the facts read
//! from live Host/session state and emits them once at their authoritative
//! transition. It performs no formatting, clock reads, or adapter policy.

const std = @import("std");

const foundation = @import("foundation");

const host_mod = @import("../host.zig");
const trace = @import("../trace.zig");
const admission = @import("admission.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const crypto = foundation.crypto;

/// Install (or clear) the live trace sink: the callback that hears this host's
/// session opens, message verbs, and closes, on the host's one thread, fields
/// borrowed per call. The embedder stamps time and formats; the core reports
/// facts only.
pub fn setTrace(self: *Host, sink: ?trace.Sink) error{WrongThread}!void {
    try admission.checkOwnerIfClaimed(self);
    self.trace_sink = sink;
}

/// Emit the open fact for `session` once, the first time it is observed open.
pub fn traceNoteOpen(self: *Host, session: *HostSession) void {
    self.assertOwner();
    const sink = self.trace_sink orelse return;
    if (session.control.trace_open_noted) return;
    if (!session.sessionOpen()) return;
    session.control.trace_open_noted = true;
    const state = &session.served.port.peer.session_state;
    const claimed = state.partnerDesignator();
    const designator: []const u8 = switch (session.role) {
        .dialed => |target| target,
        .accepted => claimed orelse "peer",
    };
    const provenance = if (self.partnerIdentity(session)) |identity|
        identity.provenance
    else |_|
        .unauthenticated;
    var session_id_digits: trace.SessionId = undefined;
    var session_id: []const u8 = &.{};
    if (state.partnerSessionKey()) |partner_key_bytes| {
        if (crypto.PeerKey.fromSlice(partner_key_bytes)) |partner_key| {
            session_id_digits = trace.sessionId(session.sessionSecret().publicKey(), partner_key);
            session_id = &session_id_digits;
        } else |_| {}
    }
    sink.emit(sink.ctx, .{ .session_open = .{
        .session = session.peer_handle,
        .designator = designator,
        .transport = session.transport,
        .provenance = provenance,
        .session_id = session_id,
        .codec = state.codec,
        .captp_version = state.captp_version,
    } });
}

/// Emit one wire message, noting the open first so dial-side ordering is exact.
pub fn traceMessage(
    self: *Host,
    session: *HostSession,
    outbound: bool,
    verb: []const u8,
    frame: []const u8,
) void {
    self.assertOwner();
    const sink = self.trace_sink orelse return;
    self.traceNoteOpen(session);
    if (!session.control.trace_open_noted) return;
    var digest: [trace.digest_bytes]u8 = undefined;
    std.crypto.hash.Blake3.hash(frame, &digest, .{});
    sink.emit(sink.ctx, .{ .message = .{
        .session = session.peer_handle,
        .outbound = outbound,
        .verb = verb,
        .frame = frame,
        .digest = digest,
    } });
}

/// Emit the close fact only for a session whose open was reported.
pub fn traceClose(self: *Host, session: *HostSession) void {
    self.assertOwner();
    const sink = self.trace_sink orelse return;
    if (!session.control.trace_open_noted) return;
    session.control.trace_open_noted = false;
    sink.emit(sink.ctx, .{ .session_close = .{ .session = session.peer_handle } });
}
