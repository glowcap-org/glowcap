//! Caller-driven Peer ingress, turn progression, stream framing, and events.
//!
//! No scheduler lives here: each call advances bounded explicit work. Inbound
//! failures use the fail-closed projection. Deferred allocator and outbound
//! pressure retain their carriers for retry and do not blame the partner.

const std = @import("std");
const codec = @import("codec");
const foundation = @import("foundation");

const model = @import("model");
const engine = @import("../mod.zig");
const events = @import("../events.zig");
const inbound = @import("../inbound.zig");
const outbound = @import("../outbound.zig");
const remote_forward = @import("../remote_forward.zig");
const outbound_drain = @import("../outbound/drain.zig");
const failures = @import("failures.zig");
const handoffs = @import("handoffs.zig");

const Peer = engine.Peer;

/// Whether a decoded event still awaits the caller's serve step. Host fairness
/// uses this to resume one session without draining a sibling in one turn.
pub fn hasEvent(self: *const Peer) bool {
    return !self.events.isEmpty();
}

/// Transfer an owned inbound frame into the next step, consuming it on every
/// outcome: queued on success, released here on failure.
/// An over-cap frame is refused immediately with a typed abort.
pub fn feedOwned(self: *Peer, frame: foundation.Frame) !void {
    var owned = frame;
    inbound.checkFrameSize(self, owned.bytes().len) catch |err| {
        owned.deinit();
        inbound.emitAbortForError(self, err);
        return err;
    };
    self.inbound.push(self.allocator, owned) catch |err| {
        owned.deinit();
        return err;
    };
}

/// Drive one unit: retry one terminal settlement, settle exact handoff work,
/// dispatch one inbound frame, or encode one pending outbound carrier. A next-
/// profile operation and mandatory listener publish atomically as one item.
pub fn step(self: *Peer) !events.StepOutcome {
    if (outbound.retryDeferredSettlement(self) catch |err| {
        failures.projectDeferredStepFailure(self, err);
        return err;
    }) return .progress;

    // Node scheduling targets this receiver after a sibling gift changes. The
    // empty path costs one count read; pressure leaves the parked row retryable.
    handoffs.settlePendingWithdraws(self) catch |err| {
        failures.projectDeferredStepFailure(self, err);
        return err;
    };

    // One ordinary unit per step. This arm alone owns inbound error projection.
    // Deferred and outbound work retain their carriers on pressure, so their
    // phase boundary projects only real protocol failures.
    if (self.inbound.pop(self.allocator)) |frame| {
        try inbound.dispatchOwnedFrame(self, frame);
        return .progress;
    }
    // A carrier still in Node staging holds every later one behind it; its
    // batch flushes this Peer when it fills or removes the row. A closed
    // session discards rows instead, so it never waits.
    if (self.blockedOnStaging() and !self.sessionIsClosed()) return .idle;
    // An answer release has no deadline of its own, since nobody waits on it.
    // So it waits for the next message and leaves in the same frame, which
    // saves one kernel send per call. When the embedder is about to park, it
    // calls `flushAnswerReleases` and the releases go alone, so a quiet
    // session still sends them (ADR-0060).
    if (outbound_drain.holdsAnswerReleases(self) and !self.session_state.hasImportRelease()) return .idle;
    if (self.pending_send.peek() != null) {
        outbound_drain.stepPending(self) catch |err| {
            failures.projectDeferredStepFailure(self, err);
            return err;
        };
        return .progress;
    }
    if (try remote_forward.drainImportRelease(self)) return .progress;
    return .idle;
}

/// Encode the answer releases `step` holds at the queue tail, for an embedder
/// about to park with nothing of its own for them to ride. True when a run
/// was encoded. Idle work otherwise, including behind Node staging, where
/// the staged carrier's batch flushes this Peer.
pub fn flushAnswerReleases(self: *Peer) !bool {
    if (self.blockedOnStaging() and !self.sessionIsClosed()) return false;
    var flushed = false;
    while (outbound_drain.holdsAnswerReleases(self)) {
        outbound_drain.stepPending(self) catch |err| {
            failures.projectDeferredStepFailure(self, err);
            return err;
        };
        flushed = true;
    }
    return flushed;
}

/// Drive until no queued work remains. The caller then drains frames and events.
pub fn stepToIdle(self: *Peer) !void {
    while ((try step(self)) != .idle) {}
}

/// Copy borrowed wire bytes into the engine's owned inbound frame: one block
/// with the shape's required alignment and a head sized for the parse, which
/// `events.Parse.decode` fills, and for the argument views
/// the decoder fills, sized by the bytes (`events.headViewsFor`). This is the
/// single shape-aware materialization used when a surfaced event or
/// netlayer-owned frame must outlive its borrowed buffer.
pub fn ownedFrameFromView(
    allocator: std.mem.Allocator,
    frame: foundation.FrameView,
) !foundation.Frame {
    return foundation.Frame.initHeaded(
        allocator,
        events.Head,
        model.view.Argument,
        events.headViewsFor(frame.bytes.len),
        frame.bytes,
        frame.shape,
    );
}

/// Dispatch a borrowed inbound frame. The transient bytes are materialized once
/// into an owned frame because the surfaced event outlives this call.
/// An over-cap frame is refused before allocation or copying.
pub fn recvBorrowed(self: *Peer, frame: foundation.FrameView) !void {
    inbound.checkFrameSize(self, frame.bytes.len) catch |err| {
        inbound.emitAbortForError(self, err);
        return err;
    };
    const owned = try ownedFrameFromView(self.allocator, frame);
    try inbound.dispatchOwnedFrame(self, owned);
}

/// Dispatch one complete transport packet. A message-framed transport
/// carries exactly one bare codec frame per packet, so the packet is the
/// frame: it is retained once and parsed once, the same door every whole
/// frame enters by (`recvBorrowed`). Extra bytes, a partial frame, a
/// malformed frame, and an oversized frame all fail there before authority
/// moves.
pub fn recvPacket(self: *Peer, packet: []const u8) !void {
    const shape = codec.dispatch.frameShape(self.inboundCodec()) orelse {
        inbound.emitAbortForError(self, error.MalformedFrame);
        return error.MalformedFrame;
    };
    try recvBorrowed(self, .{ .bytes = packet, .shape = shape });
}

/// Transfer the next surfaced event to the caller, or null when drained.
/// Inline, so the row moves from the queue into the caller's binding.
pub inline fn pollEvent(self: *Peer) ?events.Event {
    return self.events.pop(self.allocator);
}
