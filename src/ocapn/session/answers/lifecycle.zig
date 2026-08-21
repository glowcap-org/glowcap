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

/// Install a pending inbound answer we owe resolution for. Idempotent because
/// a queued engine call is installed at queue time and again on local redirect.
pub fn installInbound(self: *Session, id: model.AnswerPosition) !void {
    try apply.installAnswer(self, .inbound, id);
}

/// Install a fresh outbound answer whose resolution we await.
pub fn installOutbound(self: *Session, id: model.AnswerPosition) !void {
    try apply.installAnswer(self, .outbound, id);
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

/// Unwind a fresh V1.0 virtual answer whose resolver registration failed.
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
