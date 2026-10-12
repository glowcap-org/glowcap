//! Caller-driven Peer ingress, turn progression, stream framing, and events.
//!
//! No scheduler lives here: each call advances bounded explicit work. Inbound
//! failures use the fail-closed projection. Deferred allocator and outbound
//! pressure retain their carriers for retry and do not blame the partner.

const std = @import("std");
const codec = @import("codec");
const foundation = @import("foundation");

const engine = @import("../mod.zig");
const events = @import("../events.zig");
const inbound = @import("../inbound.zig");
const outbound = @import("../outbound.zig");
const outbound_drain = @import("../outbound/drain.zig");
const failures = @import("failures.zig");
const handoffs = @import("handoffs.zig");
const settlement = @import("settlement.zig");

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
    if (settlement.retryImportedPromiseFire(self) catch |err| {
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
    if (self.pending_send.peek() != null) {
        outbound_drain.stepPending(self) catch |err| {
            failures.projectDeferredStepFailure(self, err);
            return err;
        };
        return .progress;
    }
    return .idle;
}

/// Drive until no queued work remains. The caller then drains frames and events.
pub fn stepToIdle(self: *Peer) !void {
    while ((try step(self)) != .idle) {}
}

/// Copy borrowed wire bytes into an owned frame with the shape's required
/// alignment. This is the single shape-aware materialization used when a
/// surfaced event or netlayer-owned frame must outlive its borrowed buffer.
pub fn ownedFrameFromView(
    allocator: std.mem.Allocator,
    frame: foundation.FrameView,
) !foundation.Frame {
    switch (frame.shape) {
        .byte => {
            const storage = try allocator.dupe(u8, frame.bytes);
            return foundation.Frame.initOwned(
                allocator,
                storage,
                .byte,
                .fromByteUnits(1),
            );
        },
        .word => {
            const storage = try allocator.alignedAlloc(
                u8,
                .fromByteUnits(8),
                frame.bytes.len,
            );
            @memcpy(storage, frame.bytes);
            return foundation.Frame.initOwned(
                allocator,
                storage,
                .word,
                .fromByteUnits(8),
            );
        },
    }
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

/// Validate and dispatch one complete transport packet.
///
/// Message-framed transports carry exactly one bare codec frame per packet. The
/// active codec/profile remains the boundary authority. Extra bytes, partial
/// frames, malformed frames, and oversized frames all fail before authority
/// moves. The borrowed packet is materialized once into the owned frame retained
/// by surfaced events.
pub fn recvPacket(self: *Peer, packet: []const u8) !void {
    var scan: codec.framing.StreamScan = .{};
    const prefix = codec.dispatch.framePrefixForProfile(
        self.inboundCodec(),
        self.inboundProfile(),
        packet,
        &scan,
        self.limits().max_frame_bytes,
    );
    const decoded = switch (prefix) {
        .incomplete, .malformed => {
            inbound.emitAbortForError(self, error.MalformedFrame);
            return error.MalformedFrame;
        },
        .too_large => {
            inbound.emitAbortForError(self, error.FrameTooLarge);
            return error.FrameTooLarge;
        },
        .decoded => |value| value,
    };
    if (decoded.consumed != packet.len) {
        inbound.emitAbortForError(self, error.MalformedFrame);
        return error.MalformedFrame;
    }
    const shape = codec.dispatch.frameShape(self.inboundCodec()) orelse {
        inbound.emitAbortForError(self, error.MalformedFrame);
        return error.MalformedFrame;
    };
    const owned = ownedFrameFromView(self.allocator, .{
        .bytes = packet,
        .shape = shape,
    }) catch |err| {
        self.recordFailure(err);
        return err;
    };
    try inbound.dispatchDecodedOwnedFrame(
        self,
        owned,
        decoded.body,
        self.inboundProfile(),
    );
}

/// Outcome of framing one message off a byte-stream prefix.
pub const RecvStream = union(enum) {
    /// One frame applied. The caller may discard the first `consumed` bytes.
    consumed: usize,
    /// The prefix holds only part of a frame. Append bytes and retry.
    incomplete,
};

/// Frame, decode, validate, and apply one message from borrowed stream bytes.
/// The active codec remains the sole frame-boundary authority. A resumable scan
/// only withholds decoder work while every available byte is consumed and the
/// frame is still open. It never reports a boundary itself.
///
/// This single stream entry point fails closed at `max_frame_bytes`, preventing
/// an incomplete untrusted frame from growing its consumer without
/// end. Malformed and oversized frames project typed aborts and close. An
/// incomplete prefix changes no state.
///
/// Successive calls describe one stream: storage may grow or move, but byte
/// zero must remain the same first unconsumed byte while a frame is partial.
/// The Peer carries scan progress across calls, so repointing it at unrelated
/// bytes mid-frame invalidates that progress and can withhold a complete frame.
pub fn recvStreamPrefix(self: *Peer, buffer: []const u8) !RecvStream {
    const cap = self.session_state.limits.max_frame_bytes;
    const wire_profile = self.inboundProfile();
    const prefix = codec.dispatch.framePrefixForProfile(
        self.inboundCodec(),
        wire_profile,
        buffer,
        &self.stream_scan,
        cap,
    );
    switch (prefix) {
        .incomplete => return .incomplete,
        .malformed => {
            inbound.emitAbortForError(self, error.MalformedFrame);
            return error.MalformedFrame;
        },
        .too_large => {
            inbound.emitAbortForError(self, error.FrameTooLarge);
            return error.FrameTooLarge;
        },
        .decoded => |decoded| {
            // The prefix decoder and frame-shape registry must agree.
            const shape = codec.dispatch.frameShape(self.inboundCodec()) orelse {
                inbound.emitAbortForError(self, error.MalformedFrame);
                return error.MalformedFrame;
            };
            // OOM is local rather than a partner violation, but remains visible
            // through lastAbort.
            const owned = ownedFrameFromView(self.allocator, .{
                .bytes = buffer[0..decoded.consumed],
                .shape = shape,
            }) catch |err| {
                self.recordFailure(err);
                return err;
            };
            try inbound.dispatchDecodedOwnedFrame(
                self,
                owned,
                decoded.body,
                wire_profile,
            );
            return .{ .consumed = decoded.consumed };
        },
    }
}

/// Transfer the next surfaced event to the caller, or null when drained. The
/// queued row decodes its frame here, once, for every reader downstream.
pub fn pollEvent(self: *Peer) ?events.Event {
    const queued = self.events.pop(self.allocator) orelse return null;
    return queued.surface();
}
