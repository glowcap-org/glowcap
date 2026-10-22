//! Inbound admission and Host-latched dispatch for a byte-fed session.
//!
//! Stream delimiting and retained-tail ownership stay in the sibling session
//! wire owner. This internal leaf supplies the supported Host ingress verbs
//! through direct aliases in `host.zig`.

const std = @import("std");

const foundation = @import("foundation");
const engine = @import("engine");

const host_mod = @import("../../host.zig");
const session_wire = @import("../session.zig");
const host_pump = @import("../pump.zig");

const Host = host_mod.Host;
const HostError = host_mod.HostError;
const HostSession = session_wire.HostSession;

/// Feed one inbound frame the embedder read from its own transport (borrowed
/// for the call): dispatch what it surfaces into the vat (the before-serve hook
/// claims withdraw resolves and auto-redeems gives, and settle listeners fire
/// inside this call), then pump the node actions the dispatch queued and encode
/// every touched session's outbound. On a dispatch failure the peer projects a
/// typed `op:abort` onto the outbound queue. The flush action is still queued
/// so the embedder writes it before closing the transport.
pub fn feed(self: *Host, session: *HostSession, frame: foundation.FrameView) !void {
    try admitFeed(self, session);
    try dispatchFed(self, session, struct {
        c: *HostSession,
        f: foundation.FrameView,
        pub fn call(s: @This()) !void {
            session_wire.feedBorrowedCommitted(s.c, s.f) catch |err| {
                // Condemnation can arise while this very frame is being
                // dispatched (crossed hellos). It has already cancelled
                // the Port ingress, so the Served post-batch drive sees an
                // absent ingress; that is the successful terminal outcome,
                // not a failure of the fed peer.
                if (err == error.UnknownIngress and s.c.isTerminating()) return;
                return err;
            };
        }
    }{ .c = session, .f = frame });
}

/// The preflight every fed frame passes, and the only retryable refusal.
fn admitFeed(self: *Host, session: *HostSession) !void {
    try self.checkSession(session);
    // A sealed session's wire is the sealed byte stream; a whole plaintext
    // frame fed around the channel would bypass what the channel proves, so it
    // is refused rather than admitted unsealed.
    if (session.sealed != null) return error.SealedSessionBytesOnly;
    try self.checkOutboundAdmission(session);
}

/// Dispatch one admitted frame under the latch and settle what dispatch can
/// refuse once it has started.
fn dispatchFed(self: *Host, session: *HostSession, body: anytype) !void {
    host_pump.dispatchUnderLatch(self, session, body) catch |err| return settleStartedDispatch(self, session, err);
}

/// Settle what a dispatch can refuse once it has started. A serve that lost
/// its event under memory pressure condemns the session: `Served` already
/// removed the event, so retrying the frame would replay protocol authority.
/// Backpressure mid-dispatch is a consumed frame: its bytes dispatched or
/// stayed owned in the tail, so the next verb observes the pressure instead
/// of inviting a replay. Every other refusal is the caller's.
fn settleStartedDispatch(self: *Host, session: *HostSession, err: anytype) @TypeOf(err)!void {
    if (err == error.EventServeOutOfMemory) {
        host_pump.condemnAndClose(self, session, .resource_exhausted, "event serve failed under memory pressure");
        return;
    }
    if (err == error.OutboundBackpressure) return;
    return err;
}

/// Feed raw bytes from a byte-stream transport. Each bare codec frame must be
/// wrapped as one canonical Syrup byte string (`length:body`). This method owns
/// split prefixes/bodies, coalesced outer frames, the bounded tail, and the
/// handshake pause. With no pending tail it parses the borrowed chunk in place
/// and retains only an incomplete suffix, while a tail is active, extending it
/// is the one bounded copy. Whole-frame callers continue to use `feed`.
/// Intrinsically message-framed transports do not add this envelope.
pub fn feedBytes(self: *Host, session: *HostSession, bytes: []const u8) !void {
    try self.checkOwnedSession(session);
    try Host.checkLive(session);
    try self.checkOutboundAdmission(session);
    if (session.sealed) |channel| return feedSealedBytes(self, session, channel, bytes);
    if (bytes.len == 0 and !session.feed_tail.isActive()) return;
    const was_open = session.served.port.peer.sessionIsOpen();
    host_pump.dispatchUnderLatch(self, session, struct {
        gpa: std.mem.Allocator,
        c: *HostSession,
        bytes: []const u8,
        was_open: bool,
        pub fn call(s: @This()) !void {
            try session_wire.feedStreamChunk(s.gpa, s.c, s.bytes, s.was_open);
        }
    }{ .gpa = self.allocator, .c = session, .bytes = bytes, .was_open = was_open }) catch |err|
        return settleStartedDispatch(self, session, err);
}

/// Feed one packet from the transport shape this session was minted with.
/// Byte-stream packets are arbitrary chunks carrying ADR-0012's outer envelope.
/// Message-framed packets are exactly one bare codec frame. The transport
/// profile, not the binding or adapter language, owns that distinction.
pub fn feedTransportPacket(self: *Host, session: *HostSession, packet: []const u8) !void {
    return switch (session.wire_framing) {
        .byte_stream => self.feedBytes(session, packet),
        .message => feedMessagePacket(self, session, packet),
    };
}

fn feedMessagePacket(self: *Host, session: *HostSession, packet: []const u8) !void {
    try admitFeed(self, session);
    try dispatchFed(self, session, struct {
        c: *HostSession,
        packet: []const u8,
        pub fn call(s: @This()) !void {
            try s.c.served.port.peer.recvPacket(s.packet);
        }
    }{ .c = session, .packet = packet });
}

/// The sealed arm of `feedBytes` (ADR-0041): stage the wire bytes on the
/// channel, then consume whole handshake messages and records. Handshake
/// completion binds the channel's verified remote before any plaintext is fed,
/// each opened record's plaintext runs the same tail-and-parse the unsealed arm
/// runs, and a produced handshake reply marks the session dirty so the embedder
/// is woken to write it. A channel refusal condemns the session without an
/// abort echo and surfaces to the caller. At the opening hello the pause
/// boundary holds: remaining ciphertext stays staged and
/// `HostSession.resumeFeed` resumes it. Allocation pressure returns the caller's
/// slice only while none of it was consumed. Once a record from it has opened,
/// the receive nonce has moved, so the host owns the unread suffix the same way.
fn feedSealedBytes(self: *Host, session: *HostSession, channel: *foundation.sealed.SealedChannel, bytes: []const u8) !void {
    if (bytes.len == 0 and !session.feed_tail.isActive() and !channel.hasStagedInbound()) return;
    const was_open = session.served.port.peer.sessionIsOpen();
    host_pump.dispatchUnderLatch(self, session, struct {
        host: *Host,
        c: *HostSession,
        channel: *foundation.sealed.SealedChannel,
        bytes: []const u8,
        was_open: bool,

        /// Own the unread suffix, or retire the session when it cannot be
        /// owned: replaying ciphertext would advance the receive nonce twice.
        fn parkSuffix(s: @This(), consumed: usize) !void {
            s.channel.park(s.host.allocator, s.bytes[consumed..]) catch |err| {
                host_pump.retireSealedSession(s.host, s.c);
                return err;
            };
        }

        pub fn call(s: @This()) !void {
            const gpa = s.host.allocator;
            var consumed: usize = 0;
            while (true) {
                if (s.channel.pendingPlaintext()) |plain| {
                    session_wire.feedStreamChunk(gpa, s.c, plain, s.was_open) catch |err| {
                        // The Noise record is already authoritative. Keep
                        // its plaintext borrow and own the unread wire
                        // suffix before reporting or retrying upper-layer
                        // pressure.
                        try s.parkSuffix(consumed);
                        if (err == error.OutOfMemory or err == error.OutboundBackpressure) return;
                        return err;
                    };
                    s.channel.releasePlaintext();
                    // The opening hello is the pause boundary, as on the
                    // unsealed arm. Own later ciphertext before the caller's
                    // borrowed receive buffer expires.
                    if (!s.was_open and s.c.served.port.peer.sessionIsOpen()) {
                        try s.parkSuffix(consumed);
                        break;
                    }
                    continue;
                }

                const step = s.channel.ingest(gpa, s.bytes[consumed..]) catch |err| {
                    // The channel retired itself for anything but
                    // allocation pressure, which consumes none of this
                    // call's bytes. The slice is the caller's to retry only
                    // while no record in it has opened.
                    if (err != error.OutOfMemory) {
                        host_pump.retireSealedSession(s.host, s.c);
                        return err;
                    }
                    if (consumed == 0) return err;
                    try s.parkSuffix(consumed);
                    return;
                };
                consumed += step.consumed;
                switch (step.event) {
                    .need_input => break,
                    .handshake => continue,
                    .completed => |remote| s.c.served.port.peer.bindVerifiedChannelKey(remote),
                    .plaintext => continue,
                }
            }
            if (s.channel.hasPendingWire()) host_pump.markDirty(s.host, s.c.peer_handle);
        }
    }{ .host = self, .c = session, .channel = channel, .bytes = bytes, .was_open = was_open }) catch |err|
        return settleStartedDispatch(self, session, err);
}

/// Serve one already-polled event under the host. This is the per-event verb
/// for an embedder loop that polls its sessions' peers itself (a completion
/// loop's serve hook). Shares the `feed`/`feedBytes` latch and `finishDispatch`
/// tail: the crossed-hellos hook and the resolve interceptor run, settle
/// listeners fire under the callback latch, and the node pump runs at the
/// unwind.
///
/// The batch subtlety: the unwind's pump (`drainWork`, then `Served.driveFed`,
/// then `drainEvents`) polls and serves every event *still queued* on this
/// session's peer, so a loop's per-event hook typically fires once per inbound
/// batch, and its own `pollEvent` loop then finds null. That loses nothing:
/// every event is served through the one `Served.serveEvent` spine either way.
///
/// This verb, not a raw `session.served.serveEvent`, is the embedder's
/// entry: the raw call would run settle listeners un-latched (a listener's
/// nested verb could re-enter the host mid-dispatch) and would skip the
/// node pump that turns a served reply into a give.
pub fn serveEvent(self: *Host, session: *HostSession, event: *engine.Event) !void {
    try self.checkSession(session);
    try self.checkOutboundAdmission(session);
    host_pump.dispatchUnderLatch(self, session, struct {
        c: *HostSession,
        e: *engine.Event,
        pub fn call(s: @This()) !void {
            try s.c.served.serveEvent(&s.c.host.vat, s.e);
        }
    }{ .c = session, .e = event }) catch |err| {
        if (err == error.OutOfMemory) {
            // The caller already transferred this event with `pollEvent`;
            // there is no safe replay after a hook or Port may have
            // committed before allocation failed.
            host_pump.condemnAndClose(self, session, .resource_exhausted, "event serve failed under memory pressure");
            return;
        }
        // The caller already removed this event from the Peer. Never make
        // an applied event look retryable merely because its resulting
        // outbound work crossed the waterline.
        if (err == error.OutboundBackpressure) return;
        session.served.port.peer.emitFailure(err);
        if (session.served.port.peer.sessionIsOpen())
            session.served.port.peer.closeSession();
        return err;
    };
}
