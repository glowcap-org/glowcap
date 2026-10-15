//! Owned outbound message preparation, profile encoding, and frame transfer.
//!
//! This is the Peer send chokepoint: semantic recording happens once through
//! `engine/outbound.zig`, multi-hop delivery decomposition rejoins that same
//! path, and encoding transfers one owned frame to the outbound queue. It adds
//! no scheduler or storage authority. Peer and Session remain the owners.

const codec = @import("codec");
const foundation = @import("foundation");
const model = @import("model");

const engine = @import("../mod.zig");
const fetch = @import("../fetch.zig");
const outbound = @import("../outbound.zig");
const outbound_copying = @import("../outbound/copying.zig");

const Peer = engine.Peer;

/// Enqueue an owned `message`, taking ownership of its heap on every outcome:
/// a caller that built the message moves it in and never frees it. A deliver
/// leaves as its frame at admission and its tree is freed before this
/// returns (`outbound/encoded.zig`). The kinds the drain still inspects are
/// freed by the peer after `step` encodes them (or here, if recording
/// fails). A settlement message is the exception: its resolution moves into
/// the answer store at record time (`Session.applySentResolve`). V1.0 later
/// encodes a resolver callback. Next notifies the mandatory listener. The
/// store frees it on overwrite or answer teardown. Borrowed or static input
/// goes through `sendBorrowed` instead.
pub fn send(self: *Peer, message: model.Message) !void {
    return outbound.enqueueRecorded(self, message);
}

/// Commit a prepared bootstrap fetch onto the wire. A V1.0 fetch advertises
/// its resolver export, so the resolver link and message publish or roll back
/// together. Consumes `prepared.message` on every outcome.
pub fn sendPreparedFetch(self: *Peer, prepared: fetch.PreparedFetch) !void {
    if (prepared.resolver_export) |resolver_export| {
        self.session_state.installOutboundResolver(prepared.answer_position, resolver_export) catch |err| {
            self.session_state.releaseUnsharedExport(resolver_export);
            model.freeMessage(self.allocator, prepared.message);
            return err;
        };
        send(self, prepared.message) catch |err| {
            // The resolver mention never reached recordSend, so it still has
            // only prepareFetchSwissnum's reservation retain. Retire the link
            // and export together; a retry prepares a fresh pair.
            self.session_state.abandonResolverExport(resolver_export);
            return err;
        };
        return;
    }
    try send(self, prepared.message);
}

/// Enqueue `message`, borrowing it for the call: the caller's storage is its
/// own again when this returns. A deliver that carries only values leaves as
/// its frame with no copy. A deliver that carries a reference, handoff, or
/// set, and every other kind, is cloned into the queue, the named outbound
/// boundary copy (`outbound.enqueueBorrowed`).
pub fn sendBorrowed(self: *Peer, message: model.Message) !void {
    return outbound.enqueueBorrowed(self, message);
}

/// Enqueue a deliver whose arguments are lent as views (ADR-0246). The tree
/// must carry values only, which the session certifies, and it leaves as
/// its frame before this returns (`outbound.enqueueFreight`).
pub fn sendFreight(self: *Peer, target: model.Reference, args: model.view.Args, answer: ?model.AnswerPosition) !void {
    return outbound.enqueueFreight(self, target, args, answer);
}

pub const sendAnswerResolutionCopying = outbound_copying.answer;
pub const sendAnswerTargetResolutionCopying = outbound_copying.answerTarget;
pub const sendAnswerTargetResolutionViewCopying = outbound_copying.answerTargetView;

/// Encode `message` for the wire profile its kind uses, as one owned frame.
pub fn encodeOutbound(self: *Peer, message: model.Message) !foundation.Frame {
    const body = model.view.Body.fromOwned(&message);
    return encodeOutboundBody(self, &body);
}

/// Encode a borrowed `body` for the wire profile its kind uses, as one owned
/// frame. The owned entry projects onto this one.
pub fn encodeOutboundBody(self: *Peer, body: *const model.view.Body) !foundation.Frame {
    // A hello cannot use the profile it is negotiating, and deferred encoding
    // means the session may already be open when its queued hello reaches this
    // seam. A pre-open abort belongs to that same baseline envelope. After
    // open, abort and ordinary traffic use the active session pair.
    const active = model.Preference{
        .captp_version = self.session_state.captp_version,
        .codec = self.session_state.codec,
        .features = self.session_state.features,
    };
    const wire = switch (body.*) {
        .start_session => model.Preference.baseline,
        .abort => if (self.session_state.state == .negotiating)
            model.Preference.baseline
        else
            active,
        else => active,
    };
    return codec.dispatch.encodeBodyForProfile(
        wire.codec,
        self.allocator,
        wire.captp_version,
        body,
    );
}

/// Encode a wire message for the settled profile and push its owned frame.
/// The frame is freed on refusal and owned by the queue on success.
pub fn pushEncoded(self: *Peer, message: model.Message) !void {
    var frame = try encodeOutbound(self, message);
    errdefer frame.deinit();
    try self.checkOutboundWaterline();
    try self.outbound.push(self.allocator, frame);
}

/// Encode the front staged carrier without removing it. Encoding and queue
/// capacity may fail while the carrier remains retryable. The caller consumes
/// it only after this succeeds. No waterline stands here: the carrier's bytes
/// were admitted at staging, and completion is what lets retained state drain
/// (see `outbound/budget.zig`).
pub fn pushEncodedFromPending(self: *Peer, message: model.Message) !void {
    var frame = try encodeOutbound(self, message);
    errdefer frame.deinit();
    try self.outbound.ensureUnusedCapacity(self.allocator, 1);
    self.outbound.pushAssumeCapacity(frame);
}

pub const SecondMessageAccounting = enum {
    already_recorded,
    /// The second message is the `op:gc-exports` releasing the session's own
    /// retain on the first message's target: a fired listener's, a settled
    /// V1.0 resolver's.
    session_release_at_commit,
};

/// Encode and publish two adjacent frames as one pending-carrier transaction.
/// Both encodes and both queue slots are acquired before either frame becomes
/// visible. `session_release_at_commit` records the second message's release
/// of the session's own import retains only after every fallible preparation
/// succeeds. No waterline stands here (see `outbound/budget.zig`).
pub fn pushEncodedPairFromPending(
    self: *Peer,
    first: model.Message,
    second: model.Message,
    second_accounting: SecondMessageAccounting,
) !void {
    var first_frame = try encodeOutbound(self, first);
    errdefer first_frame.deinit();
    var second_frame = try encodeOutbound(self, second);
    errdefer second_frame.deinit();
    try self.outbound.ensureUnusedCapacity(self.allocator, 2);

    if (second_accounting == .session_release_at_commit)
        self.session_state.recordSessionImportRelease(second.gc_export);

    self.outbound.pushAssumeCapacity(first_frame);
    self.outbound.pushAssumeCapacity(second_frame);
}

/// Encode `op:abort`, then close CapTP. A terminal frame bypasses ordinary
/// waterline refusal so the partner is not left waiting on a condemned
/// session. It remains charged in the queue until the adapter drains it.
pub fn commitAbortOutbound(self: *Peer, abort: model.AbortReason) !void {
    var frame = try encodeOutbound(self, .{ .abort = abort });
    errdefer frame.deinit();
    try self.outbound.push(self.allocator, frame);
    self.closeSession();
}

/// Transfer the next encoded frame to the caller, or null when drained.
pub fn takeOutbound(self: *Peer) ?foundation.Frame {
    return self.outbound.pop(self.allocator);
}
