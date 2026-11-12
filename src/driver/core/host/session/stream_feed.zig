//! Stream delimiting and retained-tail resumption for a byte-fed Host
//! session: outer Syrup byte strings are cut from each plaintext chunk, an
//! incomplete suffix waits in the session's `feed_tail`, and a paused tail
//! resumes as its own Host drive.
//!
//! This is an internal owner. Consumers reach these verbs through `host.zig`.

const std = @import("std");

const foundation = @import("foundation");
const engine = @import("engine");

const host_mod = @import("../../host.zig");
const session_wire = @import("../session.zig");
const host_pump = @import("../pump.zig");

const Host = host_mod.Host;
const HostError = host_mod.HostError;
const HostSession = session_wire.HostSession;

/// Retained-capacity bound for a session's `feed_tail` between bursts, the
/// engine's steady-queue posture at the byte-fed tier. A burst that grew the
/// tail past this frees the excess when the tail drains, at the price of one
/// growth re-allocation when the next burst begins.
pub const steady_feed_tail_bytes: usize = 4096;

/// Apply one borrowed frame, then drive the event and outbound consequences
/// that frame committed. Only receive/admission errors escape as retryable for
/// the caller's bytes. Once `recvBorrowed` succeeds, local allocator or
/// outbound pressure parks the remaining drive on the Host dirty queue instead
/// of making an applied frame look unconsumed.
pub fn feedBorrowedCommitted(session: *HostSession, frame: foundation.FrameView) !void {
    try session.served.port.peer.recvBorrowed(frame);
    session.served.driveFed(&session.host.vat) catch |err| switch (err) {
        error.OutOfMemory, error.OutboundBackpressure => {
            host_pump.markDirty(session.host, session.peer_handle);
            return;
        },
        error.EventServeOutOfMemory => return err,
        else => {
            // The frame is authoritative and cannot be replayed. Give a
            // protocol-shaped failure its typed abort. A host-internal error
            // has no wire projection, but still closes this consumed session.
            session.served.port.peer.emitFailure(err);
            if (session.served.port.peer.sessionIsOpen())
                session.served.port.peer.closeSession();
            return err;
        },
    };
}

/// Feed one plaintext stream chunk through the tail-and-parse machinery: with
/// no pending tail, parse the borrowed chunk in place and retain only an
/// incomplete suffix. While a tail is active, extend it (the one bounded
/// copy) and parse from there. The one body both `Host.feedBytes` arms share:
/// the unsealed verb hands it the caller's bytes, the sealed arm each opened
/// record's plaintext.
pub fn feedStreamChunk(gpa: std.mem.Allocator, session: *HostSession, bytes: []const u8, was_open: bool) !void {
    const tail = &session.feed_tail;
    if (!tail.isActive()) {
        const parsed = try parseOuterStreamPrefix(session, bytes, was_open);
        if (parsed.consumed < bytes.len) {
            try tail.absorbBytes(gpa, bytes[parsed.consumed..]);
            if (parsed.needs_resume) host_pump.scheduleFeedResume(session.host, session);
        }
        return;
    }
    try tail.absorbBytes(gpa, bytes);
    const parsed = try parseOuterStreamPrefix(session, tail.bytes(), was_open);
    tail.consume(gpa, parsed.consumed, steady_feed_tail_bytes);
    if (parsed.needs_resume) host_pump.scheduleFeedResume(session.host, session);
}

/// Delimit and dispatch complete outer Syrup byte strings from `bytes`. Each
/// body is exactly one bare codec frame. The opening hello remains the pause
/// boundary, so any following outer frames stay in the caller-owned tail.
const StreamParse = struct {
    consumed: usize,
    /// The suffix starts with a complete frame held only by local pressure,
    /// rather than an incomplete frame or the post-handshake setup boundary.
    needs_resume: bool = false,
};

fn parseOuterStreamPrefix(session: *HostSession, bytes: []const u8, was_open: bool) !StreamParse {
    var consumed: usize = 0;
    while (consumed < bytes.len) {
        // A prior frame in this same chunk may have crossed the waterline.
        // Stop before dispatching another frame. The caller retains the suffix
        // in `feed_tail`, so replay is neither required nor permitted.
        if (consumed != 0 and session.served.queuedOutboundBytes() >= session.outbound_high_water_bytes)
            return .{ .consumed = consumed, .needs_resume = true };
        const outer = switch (foundation.stream_framing.parsePrefix(
            bytes[consumed..],
            session.served.port.peer.limits().max_frame_bytes,
        )) {
            .incomplete => break,
            .malformed => {
                session.served.port.peer.emitFailure(error.MalformedFrame);
                session.served.port.peer.stepToIdle() catch |err| session.served.port.peer.recordFailure(err);
                return error.MalformedFrame;
            },
            .too_large => {
                session.served.port.peer.emitFailure(error.FrameTooLarge);
                session.served.port.peer.stepToIdle() catch |err| session.served.port.peer.recordFailure(err);
                return error.FrameTooLarge;
            },
            .decoded => |decoded| decoded,
        };
        const shape = engine.frameShape(session.served.port.peer.inboundCodec()) orelse {
            session.served.port.peer.emitFailure(error.MalformedFrame);
            session.served.port.peer.stepToIdle() catch |err| session.served.port.peer.recordFailure(err);
            return error.MalformedFrame;
        };
        feedBorrowedCommitted(session, .{
            .bytes = outer.body,
            .shape = shape,
        }) catch |err| {
            // A prior prefix already applied makes this chunk committed. Keep
            // the unapplied suffix and resume it from the core-issued wake. An
            // OOM on the first direct frame still leaves the borrowed chunk
            // retryable by its caller.
            if (err == error.OutOfMemory and consumed != 0)
                return .{ .consumed = consumed, .needs_resume = true };
            return err;
        };
        consumed += outer.consumed;
        if (!was_open and session.served.port.peer.sessionIsOpen()) break;
    }
    return .{ .consumed = consumed };
}

/// Resume retained stream input without adding new transport bytes. This is a
/// Host drive: callbacks run under the same latch and unwind pump as an
/// ordinary feed, so bindings need no special retry rule.
pub fn resumeFeedTail(self: *Host, session: *HostSession) HostError!void {
    if (!session.feed_resume_pending and !session.feed_tail.isActive()) return;
    session.feed_resume_pending = false;
    const was_open = session.served.port.peer.sessionIsOpen();
    host_pump.dispatchUnderLatch(self, session, struct {
        gpa: std.mem.Allocator,
        c: *HostSession,
        was_open: bool,
        pub fn call(s: @This()) !void {
            try feedStreamChunk(s.gpa, s.c, &.{}, s.was_open);
        }
    }{ .gpa = self.allocator, .c = session, .was_open = was_open }) catch |err| {
        return switch (err) {
            // No authority moved: the owned tail remains the retry source.
            // `dispatchUnderLatch` has already queued the next FLUSH wake.
            error.OutOfMemory => retry: {
                session.feed_resume_pending = true;
                break :retry HostError.OutOfMemory;
            },
            // The event was removed before its application turn could be
            // served, so replay would duplicate protocol authority. Fail the
            // session closed and surface the resource cause to the drainer.
            error.EventServeOutOfMemory => committed_oom: {
                session.served.port.peer.recordFailure(err);
                host_pump.condemnAndClose(self, session, .resource_exhausted, "retained stream dispatch failed under memory pressure");
                break :committed_oom HostError.OutOfMemory;
            },
            // Backpressure preserves the same owned suffix. It is distinct
            // from allocation pressure so a direct core consumer can drain
            // and retry according to the public Host error contract.
            error.OutboundBackpressure => retry: {
                session.feed_resume_pending = true;
                break :retry HostError.OutboundBackpressure;
            },
            // A retained frame has no caller left that can own an arbitrary
            // dispatch error. Preserve the concrete cause in the peer's abort
            // and terminal state. The stream projection reports that state.
            else => terminal: {
                session.served.port.peer.recordFailure(err);
                host_pump.condemnAndClose(self, session, .other, @errorName(err));
                break :terminal HostError.SessionCondemned;
            },
        };
    };
}
