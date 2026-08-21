//! Owned outbound message preparation, profile encoding, and frame transfer.
//!
//! This is the Peer send chokepoint: semantic recording happens once through
//! `engine/outbound.zig`, multi-hop delivery decomposition rejoins that same
//! path, and encoding transfers one owned frame to the outbound queue. It adds
//! no scheduler or storage authority; Peer and Session remain the owners.

const codec = @import("codec");
const foundation = @import("foundation");
const model = @import("model");

const engine = @import("../mod.zig");
const fetch = @import("../fetch.zig");
const outbound = @import("../outbound.zig");
const outbound_copying = @import("../outbound/copying.zig");
const pipeline = @import("../pipeline.zig");

const Peer = engine.Peer;

/// Enqueue an owned `message` for outbound encode, taking ownership of its
/// heap on every outcome. The canonical, copy-free path: a caller that built
/// the message moves it in and never frees it. Most kinds are freed by the
/// peer after `step` encodes them (or here, if recording fails). A settlement
/// message is the exception: its resolution moves into the answer store at
/// record time (`Session.applySentResolve`). V1.0 later encodes a resolver
/// callback; next notifies the mandatory listener. The store frees it on
/// overwrite or answer teardown. Borrowed or static input goes through
/// `sendCopying` instead.
pub fn send(self: *Peer, message: model.Message) !void {
    // A multi-hop pipelined deliver (promise target carrying a non-empty path)
    // has no single-frame Syrup shape — `desc:answer` carries no path operand —
    // so it decomposes into a chain of single-hop links, each recorded and
    // enqueued through this same path (ADR-0007). Cap'n Proto alone could carry
    // a path operand directly.
    if (message == .deliver and
        message.deliver.target == .promise and
        !message.deliver.target.promise.path.isEmpty())
    {
        return sendDecomposedPipeline(self, message);
    }

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

/// Decompose a multi-hop pipelined deliver and enqueue each single-hop link in
/// send order, taking ownership of `message`. Each link is flat by construction
/// and rejoins the ordinary record/enqueue path. A mid-chain refusal frees only
/// the unsent remainder; already-enqueued links belong to the queue.
fn sendDecomposedPipeline(self: *Peer, message: model.Message) !void {
    const chain = pipeline.decomposeOutboundDeliver(
        self.allocator,
        &self.session_state,
        message,
    ) catch |err| {
        // Decomposition never partially consumes `message` before failing.
        model.freeMessage(self.allocator, message);
        return err;
    };
    defer self.allocator.free(chain.intermediates);

    var next: usize = 0;
    var terminal_owned = true;
    errdefer {
        for (chain.intermediates[next..]) |link| model.freeMessage(self.allocator, link);
        if (terminal_owned) model.freeMessage(self.allocator, chain.terminal);
    }
    while (next < chain.intermediates.len) {
        const link = chain.intermediates[next];
        // enqueueRecorded owns `link` on both outcomes; advance first so the
        // unwind cannot double-free it.
        next += 1;
        try outbound.enqueueRecorded(self, link);
    }
    terminal_owned = false;
    try outbound.enqueueRecorded(self, chain.terminal);
}

pub fn sendCopying(self: *Peer, message: model.Message) !void {
    return outbound_copying.send(self, message);
}

pub const sendAnswerResolutionCopying = outbound_copying.answer;
pub const sendAnswerTargetResolutionCopying = outbound_copying.answerTarget;

fn encodeOutbound(self: *Peer, message: model.Message) !foundation.Frame {
    // A hello cannot use the profile it is negotiating, and deferred encoding
    // means the session may already be open when its queued hello reaches this
    // seam. A pre-open abort belongs to that same baseline envelope. After
    // open, abort and ordinary traffic use the active session pair.
    const active = model.Preference{
        .captp_version = self.session_state.captp_version,
        .codec = self.session_state.codec,
        .features = self.session_state.features,
    };
    const wire = switch (message) {
        .start_session => model.Preference.baseline,
        .abort => if (self.session_state.state == .negotiating)
            model.Preference.baseline
        else
            active,
        else => active,
    };
    return codec.dispatch.encodeMessageForProfile(
        wire.codec,
        self.allocator,
        wire.captp_version,
        message,
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

/// Encode the front staged carrier without removing it. Encoding, waterline
/// admission, and queue capacity may fail while the carrier remains retryable;
/// the caller consumes it only after this succeeds.
pub fn pushEncodedFromPending(
    self: *Peer,
    staged_charge: usize,
    message: model.Message,
) !void {
    var frame = try encodeOutbound(self, message);
    errdefer frame.deinit();
    try self.checkOutboundTransferWaterline(staged_charge);
    try self.outbound.ensureUnusedCapacity(self.allocator, 1);
    self.outbound.pushAssumeCapacity(frame);
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
