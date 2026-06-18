//! Session apply: the "commit the message's effect" half of the state machine.
//!
//! The public spine is the three dispatch appliers (`applySend`, `applyRecv`,
//! `applyRecvView`), reached through `Session.recordSend` / `recordRecv` /
//! `recordRecvView`, plus the two commit steps the engine drives directly
//! (`retainSentExportRef`, `installAnswer` via `Session.installInboundAnswer`).
//! Everything else is module-local, called directly
//! (`retainSentExports(self, message)`), not methods on `Session`. Appliers run
//! only after the matching validator in `validate.zig` has proven the message
//! valid, and they mutate the authoritative tables: installing answers,
//! retaining and releasing wire-delta refcounts, introducing imports, and
//! advancing the handshake. Apply stays all-or-nothing for every typed protocol
//! refusal: validation decides them before apply mutates (the
//! prospective-import cap walk in `validate.zig` exists for exactly this), and
//! the one refusal raised here — the inbound-answer cap in `installAnswer` —
//! fires as an arm's first step, before anything commits. Only a host
//! allocation failure can interrupt an arm mid-walk; the engine treats that as
//! fatal to the session, never as state to resume from.

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;
const Error = session.Error;
const RecvViewError = session.RecvViewError;
const AnswerDirection = session.AnswerDirection;
const AnswerTable = session.AnswerTable;
const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;

pub fn applyRecvView(self: *Session, body: model.view.Body) !void {
    switch (body) {
        // The borrowed steady-state kinds share one apply body with the owned
        // retain path; the rarer owned-fallback kinds never arrive here (they
        // are routed through `recordRecv` by `recordRecvView`).
        .abort, .deliver, .resolve, .start_session => try applyRecvShared(self, body),
        else => {},
    }
}

/// The one inbound apply body for the kinds both recv representations carry
/// (`abort` / `deliver` / `resolve` / `start_session`). `anytype` over the
/// owned `model.Message` and the borrowed `model.view.Body`, exactly like the
/// validate walkers, so the two paths cannot drift.
fn applyRecvShared(self: *Session, message: anytype) !void {
    switch (message) {
        .abort => self.close(),
        .deliver => |deliver| {
            if (deliver.answer) |answer| {
                try installAnswer(self, .inbound, answer);
            }
            // A `far` argument is the partner introducing one of its exports
            // as our import (ADR-0010); install it so we hold the import we
            // were just handed (capability-passing + V1.0 resolver-callback
            // fulfill payloads).
            try installIntroducedImports(self, deliver.args, 0);
        },
        .resolve => |resolve| {
            if (self.outbound_answers.getPtr(resolve.answer)) |entry| {
                entry.status = switch (resolve.resolution) {
                    .fulfill => .fulfilled,
                    .@"break" => .broken,
                };
            }
            // A canonical `op:resolve` fulfilling with a `far` reference hands
            // us a new import (the resolved capability) — install it.
            if (resolve.resolution == .fulfill) {
                try installIntroducedImport(self, resolve.resolution.fulfill, 0);
            }
        },
        .start_session => |ss| {
            // Learn the partner's session key and location designator (duped
            // into `key_arena`: a borrowed view's wire bytes don't outlive this
            // call, and an owned message is freed by its caller). Recorded
            // before the state transition so a failure leaves the handshake
            // unmarked.
            const pubkey = sessionPubkeyBytes(ss);
            if (pubkey.len > 0) {
                self.partner_session_key = try self.key_arena.allocator().dupe(u8, pubkey);
            }
            if (ss.acceptable_location.designator.len > 0) {
                self.partner_designator = try self.key_arena.allocator().dupe(u8, ss.acceptable_location.designator);
            }
            // The verbatim location-record bytes a gifter embeds in a
            // `desc:handoff-give` ride only on the borrowed decode view; the owned
            // message shape drops them, so capture them when present.
            if (acceptableLocationRawBytes(ss)) |raw| {
                if (raw.len > 0) {
                    self.partner_acceptable_location_raw = try self.key_arena.allocator().dupe(u8, raw);
                }
            }
            if (self.handshake_local_sent) try self.transitionToOpen();
            self.handshake_remote_received = true;
        },
        else => {},
    }
}

/// The partner's session public key as raw bytes, from either start-session
/// shape: the borrowed view carries `[]const u8`, the owned message wraps the
/// same bytes in `model.PublicKey`.
fn sessionPubkeyBytes(ss: anytype) []const u8 {
    return if (comptime @TypeOf(ss.session_pubkey) == []const u8)
        ss.session_pubkey
    else
        ss.session_pubkey.bytes;
}

/// The verbatim `<ocapn-peer ...>` location bytes, present only on the borrowed
/// decode view (`?[]const u8`); the owned `model.StartSession` has no such field,
/// so the owned-apply path reports none.
fn acceptableLocationRawBytes(ss: anytype) ?[]const u8 {
    return if (comptime @hasField(@TypeOf(ss), "acceptable_location_raw"))
        ss.acceptable_location_raw
    else
        null;
}

pub fn applySend(self: *Session, message: model.Message) !void {
    // Account every `near` export we put on the wire so a later
    // `op:gc-exports` releasing the same wire-delta balances (see
    // `retainSentExports`).
    try retainSentExports(self, message);
    switch (message) {
        .deliver => |deliver| {
            if (deliver.answer) |answer| {
                try installAnswer(self, .outbound, answer);
            }
        },
        // Sending `op:get` / `op:index` / `op:untag` allocates the projected
        // answer on our side (ADR-0050): install it outbound so the partner's
        // `op:resolve` for it validates as an answer we are owed.
        .get => |get| try installAnswer(self, .outbound, get.answer),
        .index => |index| try installAnswer(self, .outbound, index.answer),
        .untag => |untag| try installAnswer(self, .outbound, untag.answer),
        // A sent `op:resolve` is routed through `applySentResolve` by
        // `recordSend`, never here — it consumes the resolution (moves it into
        // the answer store) under a single-owner contract `applySend`'s
        // borrow-the-message shape cannot express.
        .resolve => unreachable,
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
        .gc_answer => |gc_answer| try applyGcAnswerDecrementOutbound(self, gc_answer.positions),
        .start_session => {
            // Transition first (the only fallible step); set local_sent only
            // after it succeeds so a failed bootstrap install stays atomic.
            if (self.handshake_remote_received) try self.transitionToOpen();
            self.handshake_local_sent = true;
        },
        // No send-side authority change beyond the `retainSentExports`
        // accounting above: `op:listen` anchors at the engine seam, `op:handoff`
        // carries its own gift bookkeeping, and `op:abort` tears the session
        // down. Listing them explicitly (rather than `else`) makes a new
        // `model.Message` kind fail to compile until its apply decision is
        // classified here.
        .listen, .handoff, .abort => {},
    }
}

/// Apply a resolve we are sending. **Consumes `resolve.resolution`**: it is
/// moved into the inbound answer's store on success, or freed on any failure —
/// the caller never frees it (a resolve has no heap beyond its resolution). The
/// store becomes the single owner: the queued outbound carrier holds only the
/// answer position, and `Peer.step` reads the resolution back from the store to
/// encode (`mod.Outbound.settled_answer`).
///
/// Moving here — not cloning — is what closes the record/emit gap *and* keeps
/// the wire path copy-free: the status flip and the stored resolution are one
/// fact ("this inbound answer is settled, and here is its value"), so they land
/// together at record time. Storing only when the queued frame later emits split
/// them, opening a window — as wide as a whole inbound batch, since `stepInner`
/// drains all inbound before emitting any outbound — in which an answer read
/// settled with no resolution on hand; every status-reading consumer (op:listen,
/// projections, pipelined op:deliver) then had to special-case it. The invariant
/// is now structural: for every inbound answer, `status != .pending` iff a
/// resolution is stored.
pub fn applySentResolve(self: *Session, resolve: model.Resolve) !void {
    // Account every `near` export the payload puts on the wire (see
    // `retainSentExports`). On failure the resolution has found no owner, so the
    // consume contract makes us free it.
    retainSentExports(self, .{ .resolve = resolve }) catch |err| {
        model.freeResolution(self.allocator, resolve.resolution);
        return err;
    };
    // The send validator already proved the answer exists and is pending, so a
    // missing row is not reachable in practice; honour the consume contract
    // defensively rather than strand the resolution.
    if (!self.inbound_answers.contains(resolve.answer)) {
        model.freeResolution(self.allocator, resolve.resolution);
        return;
    }
    // Transfer ownership to the store (which frees the resolution on its own
    // failure, so the contract holds on every path).
    try self.storeResolution(resolve.answer, resolve.resolution);
}

pub fn applyRecv(self: *Session, message: model.Message) !void {
    switch (message) {
        .gc_export => |gc_export| try session.applyGcExportDecrement(&self.exports, gc_export),
        // Inbound `op:gc-answers` releases an answer we created for the
        // partner — decrement our inbound answers and prune the inbound
        // resolver link we recorded for it.
        .gc_answer => |gc_answer| try applyGcAnswerDecrementInbound(self, gc_answer.positions),
        // `op:get` / `op:index` / `op:untag` export a promise at the new answer
        // position (CapTP § op:get "Receiving"): install the inbound answer the
        // partner will pipeline against. The engine anchors the projection
        // itself.
        .get => |get| try installAnswer(self, .inbound, get.answer),
        .index => |index| try installAnswer(self, .inbound, index.answer),
        .untag => |untag| try installAnswer(self, .inbound, untag.answer),
        // A handoff certificate that arrives on the generic inbound path moves
        // no authority: a `desc:handoff-receive` is not a standalone OCapN
        // message (the spec withdraw is an `op:deliver` to the bootstrap object,
        // verified in `engine.bootstrap.resolveForWithdraw`), so applying a
        // withdraw here would let any peer that can reach the socket burn a
        // deposited gift without an Ed25519 check. Withdrawal authority moves
        // only through a verified caller (`resolveForWithdraw`, or a host that
        // verifies both certificates before applying the withdraw against the
        // gift registry). A top-level handoff frame still surfaces as a
        // `.handoff` event for observation.
        .handoff => {},
        // abort / deliver / resolve / start_session share one body with the
        // borrowed-view path.
        else => try applyRecvShared(self, message),
    }
}

/// Install the imports introduced by the `far` references in an argument tree
/// (a deliver's args or a resolution's fulfill payload). Each `far` is a
/// `<desc:import-object>` naming one of the partner's exports; registering it
/// records the import the session holds. The bootstrap import (0) is excluded; an
/// already-held position increments its wire-delta refcount, so a later
/// `op:gc-exports` releasing the same total delta balances.
fn installIntroducedImports(self: *Session, args: anytype, depth: usize) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    if (comptime @TypeOf(args) == model.view.Args) {
        var it = args.iterator();
        while (try it.next()) |arg| try installIntroducedImport(self, arg, depth);
    } else {
        for (args) |arg| try installIntroducedImport(self, arg, depth);
    }
}

fn installIntroducedImport(self: *Session, arg: anytype, depth: usize) RecvViewError!void {
    switch (arg) {
        .reference => |reference| switch (reference) {
            .far => |far| if (far.import_position != BOOTSTRAP_POSITION) {
                try self.registerImport(far.import_position);
            },
            else => {},
        },
        .list, .set => |items| try installIntroducedImports(self, items, depth + 1),
        .tagged => |tagged| try installIntroducedImports(self, tagged.value, depth + 1),
        .@"struct" => |entries| try installIntroducedStructImports(self, entries, depth + 1),
        // Exhaustive on purpose: a new Argument arm must decide here whether it
        // can introduce an import — see `validate.validateInboundArgument`.
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error", .handoff => {},
    }
}

/// Struct entries carry full argument values, so an introduced `far` import can
/// arrive inside one — the struct mirror of `installIntroducedImports`,
/// dual-shape over the borrowed `model.view.StructEntries` and the owned slice.
fn installIntroducedStructImports(self: *Session, entries: anytype, depth: usize) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    if (comptime @TypeOf(entries) == model.view.StructEntries) {
        var it = entries.iterator();
        while (try it.next()) |entry| try installIntroducedImport(self, entry.value, depth);
    } else {
        for (entries) |entry| try installIntroducedImport(self, entry.value, depth);
    }
}

/// Retain a wire reference for every `near` export this outbound message
/// puts on the wire — the outbound mirror of `installIntroducedImports`.
/// Each time we name one of our exports the partner gains a reference it
/// will later release with a matching `op:gc-exports` wire-delta, so each
/// mention must increment the export's refcount; otherwise a partner that
/// received an export N times and releases with delta N underflows our
/// table and spuriously aborts the session. The count carried by
/// `allocateExport` is the export's own local reference, which the
/// partner's GC can drive down to but never below, so a fully-released
/// export survives for re-export rather than being dropped mid-session. The
/// bootstrap export (0) is permanent and excluded, symmetric with the
/// import-side bootstrap exclusion. Runs in apply, after `validateSend` has
/// proven every `near` is a held export.
fn retainSentExports(self: *Session, message: model.Message) !void {
    switch (message) {
        .deliver => |deliver| {
            try retainSentExportRef(self, deliver.target);
            if (deliver.resolve_me_desc) |reference| try retainSentExportRef(self, reference);
            try retainSentExportArgs(self, deliver.args, 0);
        },
        .resolve => |resolve| switch (resolve.resolution) {
            .fulfill => |arg| try retainSentExportArg(self, arg, 0),
            .@"break" => {},
        },
        .listen => |listen| {
            try retainSentExportRef(self, listen.target);
            try retainSentExportRef(self, listen.listener);
        },
        // `op:get` / `op:index` / `op:untag` put their receiver reference on the
        // wire just like a deliver target, so a `near` receiver takes the same
        // wire-delta retain — symmetric with `validateSend`, which already proves
        // the receiver is a held export. Omitting it let a settled partner's
        // `op:gc-exports` underflow the export it never saw retained.
        .get => |get| try retainSentExportRef(self, get.receiver),
        .index => |index| try retainSentExportRef(self, index.receiver),
        .untag => |untag| try retainSentExportRef(self, untag.receiver),
        // Exhaustive on purpose — no `else`. A new sendable kind that puts a
        // reference on the wire must declare its wire-delta retain above, or this
        // switch stops compiling. That compile error is the ratchet for the gap
        // that let `op:get`/`op:index`/`op:untag` ship unaccounted: silence here
        // becomes a partner `op:gc-exports` underflow later. These kinds put no
        // `near` export mention on the wire, so they retain nothing.
        .gc_export, .gc_answer, .handoff, .start_session, .abort => {},
    }
}

/// Retain the wire mention of one sent export reference. Public because the
/// engine's V1.0 resolver augmentation
/// (`engine.v1_0.installResolverForOutboundDeliver`) puts a resolver mention
/// on the wire at encode time, bypassing `recordSend`, and must take the same
/// wire-delta retain this apply walk would have added.
pub fn retainSentExportRef(self: *Session, reference: model.Reference) !void {
    switch (reference) {
        .near => |near| if (near.export_position != BOOTSTRAP_POSITION) {
            try self.exports.retain(self.allocator, near.export_position);
        },
        else => {},
    }
}

fn retainSentExportArgs(self: *Session, args: []const model.Argument, depth: usize) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    for (args) |arg| try retainSentExportArg(self, arg, depth);
}

fn retainSentExportArg(self: *Session, arg: model.Argument, depth: usize) RecvViewError!void {
    switch (arg) {
        .reference => |reference| try retainSentExportRef(self, reference),
        .list, .set => |items| try retainSentExportArgs(self, items, depth + 1),
        .tagged => |tagged| try retainSentExportArgs(self, tagged.value, depth + 1),
        .@"struct" => |entries| {
            if (depth + 1 > self.limits.max_nesting_depth) return Error.NestingTooDeep;
            for (entries) |entry| try retainSentExportArg(self, entry.value, depth + 1);
        },
        // Exhaustive on purpose: a new Argument arm must decide here whether it
        // can name an export — see `validate.validateInboundArgument`.
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error", .handoff => {},
    }
}

/// Apply `op:gc-answers` to our inbound answers. A fully-released answer can
/// never resolve again, so its V1.0 inbound resolver link (ADR-0010) is
/// dropped with the row — an O(1) keyed removal.
fn applyGcAnswerDecrementInbound(self: *Session, positions: []const u64) Error!void {
    for (positions) |position| {
        if (try decrementAnswer(self, &self.inbound_answers, position)) {
            _ = self.v1_0_inbound_resolvers.remove(position);
        }
    }
}

/// Apply `op:gc-answers` to our outbound answers, dropping any V1.0 outbound
/// resolver link for a fully-released answer. The link map is keyed by
/// resolver-export for the hot reverse lookup, so removal-by-answer scans —
/// bounded by the outstanding resolver links and only on the GC path.
fn applyGcAnswerDecrementOutbound(self: *Session, positions: []const u64) Error!void {
    for (positions) |position| {
        if (try decrementAnswer(self, &self.outbound_answers, position)) {
            removeOutboundResolverByAnswer(self, position);
        }
    }
}

fn removeOutboundResolverByAnswer(self: *Session, answer: u64) void {
    var it = self.v1_0_outbound_resolvers.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == answer) {
            self.v1_0_outbound_resolvers.removeByPtr(entry.key_ptr);
            return;
        }
    }
}

/// Decrement an answer's refcount, removing it at zero. Returns whether the
/// answer was fully released (count reached zero). Releasing an answer frees
/// any queued pipelined calls, listeners, and stored resolution it owns.
fn decrementAnswer(self: *Session, table: *AnswerTable, position: u64) Error!bool {
    const entry = table.getPtr(position) orelse return Error.GcUnderflow;
    if (entry.count == 0) return Error.GcUnderflow;
    entry.count -= 1;
    if (entry.count == 0) {
        session.deinitAnswerEntry(self.allocator, entry);
        table.remove(position);
        return true;
    }
    return false;
}

/// Install a pending answer row in the table `direction` names. Inbound rows
/// are partner-named and capped by `SessionLimits.max_inbound_answers`;
/// outbound rows are positions we allocate, bounded by our own sends, so the
/// cap is the direction's policy, not a property of which pointer was passed.
/// Idempotent: an already-present row is left untouched (the engine installs a
/// queued pipelined call's answer at queue time and again at redirect time).
pub fn installAnswer(self: *Session, direction: AnswerDirection, position: u64) !void {
    const table = switch (direction) {
        .inbound => &self.inbound_answers,
        .outbound => &self.outbound_answers,
    };
    if (table.contains(position)) return;
    if (direction == .inbound and table.len() >= self.limits.max_inbound_answers) {
        return Error.InboundAnswerCapExceeded;
    }
    try table.put(self.allocator, position, .{ .status = .pending, .count = 1 });
}
