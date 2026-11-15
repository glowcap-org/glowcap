//! Stream delimiting and retained-tail resumption for a byte-fed Host
//! session: outer Syrup byte strings are cut from each plaintext chunk, an
//! incomplete suffix waits in the session's `feed_tail`, and a paused tail
//! resumes as its own Host drive.
//!
//! A refusal that leaves the session open has committed nothing: it is the
//! frame's own allocation or the tail's.
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

/// Feed one plaintext stream chunk through the tail-and-parse machinery. The
/// tail holds the front of one incomplete frame or, while dispatch is paused
/// (the opening hello, outbound pressure), every byte behind the pause. A
/// chunk arriving behind an incomplete frame gives up only the bytes that
/// complete it. Once the frame dispatches, the tail empties and the rest of the
/// chunk parses in place when nothing pauses. A paused tail absorbs the chunk
/// behind it, so order holds. An `OutOfMemory` before any frame dispatched
/// leaves the tail as it was on entry, so the caller's chunk is retryable. Once
/// a frame has dispatched, pressure retains the unread suffix in the tail and
/// schedules its resume. A suffix the tail cannot retain returns
/// `error.StreamTailOutOfMemory`, which retires the session and is never
/// retryable, because the stream position is lost with the suffix.
/// The one body both `Host.feedBytes` arms share: the unsealed verb hands it
/// the caller's bytes, the sealed arm each opened record's plaintext.
pub fn feedStreamChunk(gpa: std.mem.Allocator, session: *HostSession, bytes: []const u8, was_open: bool) !void {
    const tail = &session.feed_tail;
    if (!tail.isActive()) return feedBorrowed(gpa, session, bytes, was_open, false);
    const peer = session.served.port.peer;
    const mark = tail.len;
    switch (try foundation.stream_framing.completeFirstFrame(tail, gpa, bytes, peer.limits().max_frame_bytes)) {
        .waiting => return,
        .frame => |frame| {
            // The frame's own allocation is the one refusal here that leaves
            // the session open, and it commits nothing.
            dispatchBody(session, frame.body) catch |err| {
                tail.truncate(mark);
                return err;
            };
            tail.consume(gpa, tail.len, steady_feed_tail_bytes);
            return feedBorrowed(gpa, session, bytes[frame.used..], was_open, true);
        },
        .parse => |used| {
            errdefer tail.truncate(mark);
            try tail.absorbBytes(gpa, bytes[used..]);
            const parsed = try parseOuterStreamPrefix(session, tail.bytes(), was_open, false);
            tail.consume(gpa, parsed.consumed, steady_feed_tail_bytes);
            if (parsed.needs_resume) host_pump.scheduleFeedResume(session.host, session);
        },
    }
}

/// Parse `bytes` in place and retain only the unread suffix in the tail.
/// `committed` says a frame of this same call already dispatched. A suffix
/// the tail cannot hold is a retryable `OutOfMemory` while nothing dispatched
/// and `StreamTailOutOfMemory` once a frame did, because the stream position
/// is lost with the suffix.
fn feedBorrowed(gpa: std.mem.Allocator, session: *HostSession, bytes: []const u8, was_open: bool, committed: bool) !void {
    const parsed = try parseOuterStreamPrefix(session, bytes, was_open, committed);
    if (parsed.consumed < bytes.len) {
        session.feed_tail.absorbBytes(gpa, bytes[parsed.consumed..]) catch |err| {
            if (!committed and parsed.consumed == 0) return err;
            return error.StreamTailOutOfMemory;
        };
        if (parsed.needs_resume) host_pump.scheduleFeedResume(session.host, session);
    }
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

/// The first outer frame of `bytes`, or null while it is incomplete. A
/// malformed or oversize prefix projects its abort and returns its error.
fn nextFrame(session: *HostSession, bytes: []const u8) !?struct { body: []const u8, consumed: usize } {
    const peer = session.served.port.peer;
    switch (foundation.stream_framing.parsePrefix(bytes, peer.limits().max_frame_bytes)) {
        .incomplete => return null,
        .malformed => return refuse(peer, error.MalformedFrame),
        .too_large => return refuse(peer, error.FrameTooLarge),
        .decoded => |decoded| return .{ .body = decoded.body, .consumed = decoded.consumed },
    }
}

const Refusal = error{ MalformedFrame, FrameTooLarge };

fn refuse(peer: *engine.Peer, err: Refusal) Refusal {
    peer.emitFailure(err);
    peer.stepToIdle() catch |step_err| peer.recordFailure(step_err);
    return err;
}

/// Apply one frame body, then drive what it committed.
fn dispatchBody(session: *HostSession, body: []const u8) !void {
    const peer = session.served.port.peer;
    const shape = engine.frameShape(peer.inboundCodec()) orelse return refuse(peer, error.MalformedFrame);
    try feedBorrowedCommitted(session, .{ .bytes = body, .shape = shape });
}

/// Dispatch whole outer frames from the front of `bytes`. `committed` says a
/// frame of this same call already dispatched, so pressure on the first frame
/// here keeps the unread suffix instead of returning a retryable error.
fn parseOuterStreamPrefix(session: *HostSession, bytes: []const u8, was_open: bool, committed: bool) !StreamParse {
    var consumed: usize = 0;
    while (consumed < bytes.len) {
        const dispatched = committed or consumed != 0;
        // The opening hello is the pause boundary: later frames wait in the
        // tail until the session's own drive resumes them.
        if (dispatched and !was_open and session.served.port.peer.sessionIsOpen()) break;
        // A prior frame in this same call may have crossed the waterline.
        // Stop before dispatching another frame. The caller retains the suffix
        // in `feed_tail`, so replay is neither required nor permitted.
        if (dispatched and session.outboundAtWaterline())
            return .{ .consumed = consumed, .needs_resume = true };
        const outer = (try nextFrame(session, bytes[consumed..])) orelse break;
        dispatchBody(session, outer.body) catch |err| {
            // A prior frame already applied makes this call committed. Keep
            // the unapplied suffix and resume it from the core-issued wake. An
            // OOM on the first direct frame of an uncommitted call still
            // leaves the borrowed chunk retryable by its caller.
            if (err == error.OutOfMemory and dispatched)
                return .{ .consumed = consumed, .needs_resume = true };
            return err;
        };
        consumed += outer.consumed;
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
