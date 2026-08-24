//! Answer-row installation, identity stamping, and pre-publication unwind.
//!
//! Ordinary partner-visible retirement remains in notification/GC owners.
//! These operations own only row birth and rollback before an answer becomes
//! observable, plus the exact retained-resolution accounting released with an
//! inbound row.

const std = @import("std");
const model = @import("model");

const apply = @import("../apply.zig");
const session = @import("../mod.zig");
const store = @import("store.zig");

const AnswerCell = store.AnswerCell;
const Session = session.Session;

pub const Direction = enum { inbound, outbound };

/// Install a pending inbound answer we owe resolution for.
pub fn installInbound(self: *Session, id: model.AnswerPosition) !void {
    try apply.installAnswer(self, .inbound, id);
}

/// Install a fresh outbound answer whose resolution we await.
pub fn installOutbound(self: *Session, id: model.AnswerPosition) !void {
    try apply.installAnswer(self, .outbound, id);
}

/// Transfer a live outbound answer's sole application-release responsibility
/// out of the stateless serve policy. Returns false when a delayed send has not
/// published its answer row yet. The claimant must eventually send the exact
/// `op:gc-answers` decrement or let session teardown retire the row.
pub fn claimOutboundRelease(self: *Session, id: model.AnswerPosition) bool {
    const entry = self.outbound_answers.getPtr(id) orelse return false;
    std.debug.assert(!entry.application_release_claimed);
    entry.application_release_claimed = true;
    return true;
}

/// Reserve storage for one fresh inbound answer without publishing its name.
/// The caller has already selected the wire or virtual namespace identity and
/// commits it only after the rest of the inbound frame is prepared.
pub fn prepareFreshInboundNamed(self: *Session, id: model.AnswerName) !void {
    if (self.inbound_answers.contains(id)) return session.Error.UnexpectedMessage;
    if (self.inboundAnswerObligationCount() >= self.limits.max_inbound_answers)
        return session.Error.InboundAnswerCapExceeded;
    try self.inbound_answers.ensureUnusedCapacity(self.allocator, 1);
}

/// Publish an inbound answer after `prepareFreshInboundNamed`. No allocation
/// or protocol refusal remains at this commit point.
pub fn commitFreshInboundNamed(self: *Session, id: model.AnswerName) void {
    std.debug.assert(!self.inbound_answers.contains(id));
    std.debug.assert(self.inboundAnswerObligationCount() < self.limits.max_inbound_answers);
    self.inbound_answers.putAssumeCapacity(
        id,
        AnswerCell.initPending(nextStoreStamp(self)),
    );
}

/// Mint the next store-row stamp. Zero is excluded so an initialized carrier
/// cannot false-match a row, and wrap is pinned rather than aliasing history.
pub fn nextStoreStamp(self: *Session) u64 {
    self.store_stamp_counter += 1;
    std.debug.assert(self.store_stamp_counter != 0);
    return self.store_stamp_counter;
}

/// Unwind an outbound answer installed for a send that never reached the wire.
/// The monotonic position remains spent; partner-visible rows retire through
/// answer GC instead.
pub fn abandonOutbound(self: *Session, id: model.AnswerPosition) void {
    const entry = self.outbound_answers.getPtr(id) orelse unreachable;
    std.debug.assert(entry.status() == .pending and entry.count == 1);
    _ = store.deinitAnswerCell(self.allocator, entry);
    self.outbound_answers.remove(id);
}

/// Release one committed outbound answer owned only by the local application.
/// Unlike `abandonOutbound`, the answer may already be settled and its resolver
/// export may already be visible to the partner. The resolver therefore becomes
/// a tombstone until a callback in flight is consumed and the partner releases
/// its export mention.
pub fn releaseOutbound(self: *Session, id: model.AnswerPosition) session.Error!void {
    const entry = self.outbound_answers.getPtr(id) orelse return session.Error.GcUnderflow;
    if (entry.count == 0) return session.Error.GcUnderflow;
    const final_release = entry.count == 1;
    const retired_state: session.RetiredResolverState = if (entry.status() == .pending)
        .pending
    else
        .complete;
    const settling_source = if (final_release)
        self.unlinkPromiseSettlingAnswer(id)
    else
        null;

    entry.count -= 1;
    if (entry.count != 0) return;
    const released = store.deinitAnswerCell(self.allocator, entry);
    std.debug.assert(released == 0);
    self.outbound_answers.remove(id);
    self.retireApplicationResolver(id, retired_state, settling_source);
}

/// Unwind a fresh inbound answer that was never published.
pub fn abandonUnsharedInbound(self: *Session, id: model.AnswerPosition) void {
    return abandonUnsharedInboundNamed(self, .fromWire(id));
}

/// Named form of `abandonUnsharedInbound` for wire and virtual answers.
pub fn abandonUnsharedInboundNamed(self: *Session, id: model.AnswerName) void {
    const entry = self.inbound_answers.getPtr(id) orelse unreachable;
    std.debug.assert(entry.status() == .pending and entry.count == 1);
    releaseInboundCell(self, entry);
    self.inbound_answers.remove(id);
}

/// Retire one inbound cell and release its exact retained-resolution charge.
pub fn releaseInboundCell(self: *Session, entry: *AnswerCell) void {
    const released = store.deinitAnswerCell(self.allocator, entry);
    std.debug.assert(self.retained_sent_answer_bytes >= released);
    self.retained_sent_answer_bytes -= released;
}
