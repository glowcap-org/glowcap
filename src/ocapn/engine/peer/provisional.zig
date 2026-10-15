//! The provisional window: far sends a Vat turn makes, held retractable until
//! the turn's outcome (ADR-0194).
//!
//! While the window is open, `pushPendingAssume` marks each answered or
//! answerless deliver it queues. The embedder does not step a Peer while its
//! Vat executes, so a marked row is still here when the outcome arrives, and
//! it carries what recording it did: the exports it retained, the answer it
//! installed, and the resolver it minted (`outbound/encoded.zig`). Commit
//! clears the marks. Retraction removes each marked row, which keeps every
//! other row in order, and undoes exactly that. A row that a step emitted
//! before the outcome has left the Peer, carries no mark any more, and stays
//! sent.

const std = @import("std");
const model = @import("model");

const engine = @import("../mod.zig");
const semantic = @import("../outbound.zig");

const Peer = engine.Peer;

/// The carriers a turn's far send produces: a deliver, or on `next` a deliver
/// paired with its mandatory answer listener.
pub fn retractable(item: semantic.Outbound) bool {
    return switch (item) {
        .encoded => |sent| sent.op == .deliver,
        .staged => |staged| staged.deliver,
        else => false,
    };
}

pub fn open(self: *Peer) void {
    std.debug.assert(!self.provisional);
    self.provisional = true;
}

pub fn commit(self: *Peer) void {
    std.debug.assert(self.provisional);
    self.provisional = false;
    for (self.pending_send.pending()) |*row| row.provisional = false;
    if (self.node_services) |services| services.provisionalClosed(false);
}

/// Retract every marked row and close the window. `retracted` learns the
/// answer of each retracted deliver that had one, so its owner can break the
/// vow waiting on it.
pub fn retract(
    self: *Peer,
    ctx: *anyopaque,
    retracted: *const fn (ctx: *anyopaque, answer: model.AnswerPosition) void,
) void {
    std.debug.assert(self.provisional);
    self.provisional = false;
    // Newest first: a later send may name an earlier one's answer.
    var i = self.pending_send.pending().len;
    while (i != 0) {
        i -= 1;
        const row = self.pending_send.pending()[i];
        if (!row.provisional) continue;
        if (row.item == .staged) {
            // The carrier is still in Node staging. Removing its row first
            // lets the Node fail the batch without finding it again; the
            // failure breaks the send's answer.
            self.pending_send.removePending(i);
            if (self.node_services) |services| services.stagedWithdrawn(row.item.staged.batch);
            continue;
        }
        const sent = switch (row.item) {
            .encoded => |sent| sent,
            else => unreachable,
        };
        // The resolver link names the answer, so it goes first.
        if (sent.resolver) |resolver| self.session_state.abandonMentionedResolverExport(resolver);
        self.session_state.retractSend(sent.exports, sent.answer);
        const answer = sent.answer;
        self.pending_send.removePending(i);
        std.debug.assert(self.pending_send_bytes >= row.charge);
        self.pending_send_bytes -= row.charge;
        row.item.deinit(self);
        if (answer) |position| retracted(ctx, position);
    }
    if (self.pending_send_reservations == 0 and self.pending_send.isEmpty())
        self.pending_send.trimDrained(self.allocator);
    if (self.node_services) |services| services.provisionalClosed(true);
}
