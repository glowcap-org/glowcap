//! The session bounds a fuzz target holds a peer to, and the caps that make
//! holding it mean something.
//!
//! These are one idea, not two. The check is only worth running against caps a
//! short program can cross: the shipped defaults allow a million imports and a
//! megabyte frame, and a few dozen steps cannot approach either, so asserting
//! them there would be decoration that could never fail whichever way the code
//! behaved. Shrunk to single digits, one path that inserts a row without
//! consulting its check is findable in a handful of steps.
//!
//! Both live here so a fourth bounded table is one edit rather than two, and so
//! the reason they are small is written once.

const std = @import("std");
const glowcap = @import("glowcap");

const session = glowcap.ocapn.session;

/// Caps small enough for a short program to cross.
///
/// The frame cap and the nesting depth also matter: at the shipped megabyte a
/// four-kilobyte input can never reach the cap-during-scan verdict, and at
/// sixty-four levels an deeply nested argument tree is out of reach too.
pub const tight: session.SessionLimits = .{
    .max_frame_bytes = 512,
    .max_imports = 8,
    .max_inbound_answers = 8,
    .queue_cap = 4,
    .max_queued_call_bytes = 4096,
    .max_retained_sent_answer_bytes = 4096,
    .max_listeners_per_target = 4,
    .max_nesting_depth = 4,
};

/// Every table the session declares a bound for is inside it.
///
/// A partner's whole goal is to make the process hold memory it should not, and
/// a table growing past its declared cap does exactly that without ever
/// crashing. A fuzzer looking only for crashes would run past it forever.
pub fn checkDeclared(state: *const session.Session) !void {
    const caps = state.limits;
    try std.testing.expect(session.inspect.importCount(state) <= caps.max_imports);
    try std.testing.expect(session.inspect.inboundAnswerCount(state) <= caps.max_inbound_answers);
    try std.testing.expect(state.queued_call_bytes <= caps.max_queued_call_bytes);
    try std.testing.expect(state.retained_sent_answer_bytes <= caps.max_retained_sent_answer_bytes);

    // Not the outbound answer count. Those positions are ones we allocate for
    // our own sends, and `installOutboundAnswer` holds them to no cap; only
    // the inbound table is partner-named and capped. Holding our own sends to a
    // cap meant for the partner's is not a security property, and it fails on
    // perfectly legitimate traffic once a program sends enough delivers.

    // The fan-out caps, which are the ones a partner leans on hardest: one
    // `op:listen` per slot and one pipelined call per queue slot, both against a
    // single answer. Projections share the listener cap (ADR-0004).
    var walk = PerAnswer{ .caps = caps };
    session.inspect.forEachInboundAnswer(state, &walk, PerAnswer.check);
    session.inspect.forEachOutboundAnswer(state, &walk, PerAnswer.check);
    try std.testing.expect(walk.within);
}

/// Folded over every answer row, because these caps are per answer rather than
/// per table.
const PerAnswer = struct {
    caps: session.SessionLimits,
    within: bool = true,

    fn check(self: *PerAnswer, row: session.AnswerRowView) void {
        if (row.view.queued_calls > self.caps.queue_cap) self.within = false;
        if (row.view.listeners > self.caps.max_listeners_per_target) self.within = false;
        if (row.view.projections > self.caps.max_listeners_per_target) self.within = false;
    }
};
