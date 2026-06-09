//! Session apply: the "commit the message's effect" half of the state machine.
//!
//! These are methods of [`Session`] (aliased into the struct in `mod.zig`), so
//! `self.applySend(msg)` resolves the same as before the split. They run only
//! after the matching validator in `validate.zig` has proven the message valid,
//! and they mutate the authoritative tables: installing answers, retaining and
//! releasing wire-delta refcounts, introducing imports, and advancing the
//! handshake. Apply is written to stay all-or-nothing — any fallible step runs
//! before the irreversible flag flip — so a failure leaves the session
//! untouched.

const std = @import("std");
const model = @import("../model/mod.zig");
const session = @import("mod.zig");

const Session = session.Session;
const Error = session.Error;
const RecvViewError = session.RecvViewError;
const AnswerTable = session.AnswerTable;
const BOOTSTRAP_EXPORT_ID = session.BOOTSTRAP_EXPORT_ID;

pub fn applyRecvView(self: *Session, body: model.view.Body) !void {
    switch (body) {
        .abort => self.close(),
        .deliver => |deliver| {
            if (deliver.answer) |answer| {
                try self.installAnswer(&self.inbound_answers, answer);
            }
            try self.installIntroducedImports(deliver.args, 0);
        },
        .resolve => |resolve| {
            if (self.outbound_answers.getPtr(resolve.answer)) |entry| {
                entry.status = switch (resolve.resolution) {
                    .fulfill => .fulfilled,
                    .break_ => .broken,
                };
            }
            if (resolve.resolution == .fulfill) {
                try self.installIntroducedImport(resolve.resolution.fulfill, 0);
            }
        },
        .start_session => |ss| {
            // Learn the partner's session key (duped into `key_arena`, since the
            // view borrows wire bytes that don't outlive this call). One partner
            // key per session, recorded before the state transition so a failure
            // leaves the handshake unmarked.
            if (ss.session_pubkey.len > 0) {
                self.partner_session_key = try self.key_arena.allocator().dupe(u8, ss.session_pubkey);
            }
            if (ss.acceptable_location.designator.len > 0) {
                self.partner_designator = try self.key_arena.allocator().dupe(u8, ss.acceptable_location.designator);
            }
            if (self.handshake_local_sent) try self.transitionToOpen();
            self.handshake_remote_received = true;
        },
        else => {},
    }
}

pub fn applySend(self: *Session, message: model.Message) !void {
    // Account every `near` export we put on the wire so a later
    // `op:gc-exports` releasing the same wire-delta balances (see
    // `retainSentExports`).
    try self.retainSentExports(message);
    switch (message) {
        .deliver => |deliver| {
            if (deliver.answer) |answer| {
                try self.installAnswer(&self.outbound_answers, answer);
            }
        },
        .resolve => |resolve| {
            if (self.inbound_answers.getPtr(resolve.answer)) |entry| {
                entry.status = switch (resolve.resolution) {
                    .fulfill => .fulfilled,
                    .break_ => .broken,
                };
            }
        },
        .gc_export => |gc_export| {
            try session.applyGcExportDecrement(&self.imports, gc_export);
            // ADR-0009: a fully-released third-party import can never receive
            // a relayed resolution, so drop its imported-promise row (host +
            // listeners + stored resolution) alongside the import.
            for (gc_export.positions) |pos| {
                if (!self.imports.contains(pos)) {
                    if (self.findImportedPromise(pos)) |entry| {
                        session.deinitImportedPromise(self.allocator, entry);
                        _ = self.imported_promises.remove(pos);
                    }
                }
            }
        },
        // Outbound `op:gc-answers` releases a question we asked — decrement
        // our outbound answers and drop any outbound resolver link we
        // committed for it.
        .gc_answer => |gc_answer| try self.applyGcAnswerDecrementOutbound(gc_answer.positions),
        .start_session => {
            // Transition first (the only fallible step); set local_sent only
            // after it succeeds so a failed bootstrap install stays atomic.
            if (self.handshake_remote_received) try self.transitionToOpen();
            self.handshake_local_sent = true;
        },
        else => {},
    }
}

pub fn applyRecv(self: *Session, message: model.Message) !void {
    switch (message) {
        .abort => self.close(),
        .deliver => |deliver| {
            if (deliver.answer) |answer| {
                try self.installAnswer(&self.inbound_answers, answer);
            }
            // A `far` argument is the partner introducing one of its exports
            // as our import (ADR-0010); install it so we hold the import we
            // were just handed (capability-passing + V1.0 resolver-callback
            // fulfill payloads).
            try self.installIntroducedImports(deliver.args, 0);
        },
        .resolve => |resolve| {
            if (self.outbound_answers.getPtr(resolve.answer)) |entry| {
                entry.status = switch (resolve.resolution) {
                    .fulfill => .fulfilled,
                    .break_ => .broken,
                };
            }
            // A canonical `op:resolve` fulfilling with a `far` reference hands
            // us a new import (the resolved capability) — install it.
            if (resolve.resolution == .fulfill) {
                try self.installIntroducedImport(resolve.resolution.fulfill, 0);
            }
        },
        .gc_export => |gc_export| try session.applyGcExportDecrement(&self.exports, gc_export),
        // Inbound `op:gc-answers` releases an answer we created for the
        // partner — decrement our inbound answers and prune the inbound
        // resolver link we recorded for it.
        .gc_answer => |gc_answer| try self.applyGcAnswerDecrementInbound(gc_answer.positions),
        .start_session => {
            // Bootstrap-install (the only fallible step) before flipping the
            // received flag, so apply stays all-or-nothing.
            if (self.handshake_local_sent) try self.transitionToOpen();
            self.handshake_remote_received = true;
        },
        .handoff => |handoff| switch (handoff) {
            .receive => |receive| try self.applyInboundWithdraw(receive),
            .give => {},
        },
        else => {},
    }
}

/// Install the imports introduced by the `far` references in an argument tree
/// (a deliver's args or a resolution's fulfill payload). Each `far` is a
/// `<desc:import-object>` naming one of the partner's exports; registering it
/// records the import we now hold. Already-held ids and the bootstrap import
/// (0) are no-ops.
pub fn installIntroducedImports(self: *Session, args: anytype, depth: usize) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    if (comptime @TypeOf(args) == model.view.Args) {
        var it = args.iterator();
        while (try it.next()) |arg| try self.installIntroducedImport(arg, depth);
    } else {
        for (args) |arg| try self.installIntroducedImport(arg, depth);
    }
}

pub fn installIntroducedImport(self: *Session, arg: anytype, depth: usize) RecvViewError!void {
    switch (arg) {
        .reference => |reference| switch (reference) {
            .far => |far| if (far.import_id != BOOTSTRAP_EXPORT_ID) {
                try self.registerImport(far.import_id);
            },
            else => {},
        },
        .list, .set => |items| try self.installIntroducedImports(items, depth + 1),
        .tagged => |tagged| try self.installIntroducedImports(tagged.value, depth + 1),
        else => {},
    }
}

/// Retain a wire reference for every `near` export this outbound message
/// puts on the wire — the outbound mirror of [`installIntroducedImports`].
/// Each time we name one of our exports the partner gains a reference it
/// will later release with a matching `op:gc-exports` wire-delta, so each
/// mention must increment the export's refcount; otherwise a partner that
/// received an export N times and releases with delta N underflows our
/// table and spuriously aborts the session. The count carried by
/// [`allocateExport`] is the export's own local reference, which the
/// partner's GC can drive down to but never below, so a fully-released
/// export survives for re-export rather than being dropped mid-session. The
/// bootstrap export (0) is permanent and excluded, symmetric with the
/// import-side bootstrap exclusion. Runs in apply, after `validateSend` has
/// proven every `near` is a held export.
pub fn retainSentExports(self: *Session, message: model.Message) !void {
    switch (message) {
        .deliver => |deliver| {
            try self.retainSentExportRef(deliver.target);
            if (deliver.resolve_me_desc) |reference| try self.retainSentExportRef(reference);
            try self.retainSentExportArgs(deliver.args, 0);
        },
        .resolve => |resolve| switch (resolve.resolution) {
            .fulfill => |arg| try self.retainSentExportArg(arg, 0),
            .break_ => {},
        },
        .listen => |listen| {
            try self.retainSentExportRef(listen.target);
            try self.retainSentExportRef(listen.listener);
        },
        else => {},
    }
}

pub fn retainSentExportRef(self: *Session, reference: model.Reference) !void {
    switch (reference) {
        .near => |near| if (near.export_id != BOOTSTRAP_EXPORT_ID) {
            try self.exports.retain(self.allocator, near.export_id);
        },
        else => {},
    }
}

pub fn retainSentExportArgs(self: *Session, args: []const model.Argument, depth: usize) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    for (args) |arg| try self.retainSentExportArg(arg, depth);
}

pub fn retainSentExportArg(self: *Session, arg: model.Argument, depth: usize) RecvViewError!void {
    switch (arg) {
        .reference => |reference| try self.retainSentExportRef(reference),
        .list, .set => |items| try self.retainSentExportArgs(items, depth + 1),
        .tagged => |tagged| try self.retainSentExportArgs(tagged.value, depth + 1),
        else => {},
    }
}

/// Apply `op:gc-answers` to our inbound answers. A fully-released answer can
/// never resolve again, so its V1.0 inbound resolver link (ADR-0010) is
/// dropped with the row — an O(1) keyed removal.
pub fn applyGcAnswerDecrementInbound(self: *Session, positions: []const u64) Error!void {
    for (positions) |id| {
        if (try self.decrementAnswer(&self.inbound_answers, id)) {
            _ = self.v1_0_inbound_resolvers.remove(id);
        }
    }
}

/// Apply `op:gc-answers` to our outbound answers, dropping any V1.0 outbound
/// resolver link for a fully-released answer. The link map is keyed by
/// resolver-export for the hot reverse lookup, so removal-by-answer scans —
/// bounded by the outstanding resolver links and only on the GC path.
pub fn applyGcAnswerDecrementOutbound(self: *Session, positions: []const u64) Error!void {
    for (positions) |id| {
        if (try self.decrementAnswer(&self.outbound_answers, id)) {
            self.removeOutboundResolverByAnswer(id);
        }
    }
}

pub fn removeOutboundResolverByAnswer(self: *Session, answer: u64) void {
    var it = self.v1_0_outbound_resolvers.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == answer) {
            _ = self.v1_0_outbound_resolvers.remove(entry.key_ptr.*);
            return;
        }
    }
}

/// Decrement an answer's refcount, removing it at zero. Returns whether the
/// answer was fully released (count reached zero). Releasing an answer frees
/// any queued pipelined calls, listeners, and stored resolution it owns.
pub fn decrementAnswer(self: *Session, table: *AnswerTable, id: u64) Error!bool {
    const entry = table.getPtr(id) orelse return Error.GcUnderflow;
    if (entry.count == 0) return Error.GcUnderflow;
    entry.count -= 1;
    if (entry.count == 0) {
        session.deinitAnswerEntry(self.allocator, entry);
        table.remove(id);
        return true;
    }
    return false;
}

pub fn installAnswer(self: *Session, table: *AnswerTable, id: u64) !void {
    if (table.contains(id)) return;
    // The row cap bounds the partner's answers we hold (the inbound table);
    // outbound answers are ones we allocate and are bounded by our own sends.
    if (table == &self.inbound_answers and
        table.len() >= self.limits.max_inbound_answers)
    {
        return Error.InboundAnswerCapExceeded;
    }
    try table.put(self.allocator, id, .{ .status = .pending, .count = 1 });
}
