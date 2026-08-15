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
const validate = @import("validate.zig");

const Session = session.Session;
const Error = session.Error;
const RecvViewError = session.RecvViewError;
const AnswerDirection = session.AnswerDirection;
const AnswerTable = session.AnswerTable;
const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;
const slot = session.slot;

pub fn applyRecvView(self: *Session, body: model.view.Body, introduced: *const validate.IntroducedImports) !void {
    switch (body) {
        // The borrowed steady-state kinds share one apply body with the owned
        // retain path; the rarer owned-fallback kinds never arrive here (they
        // are routed through `recordRecv` by `recordRecvView`).
        .abort, .deliver, .resolve, .start_session => try applyRecvShared(self, body, introduced),
        // The owned dispatch's twin arms: a projection op exports a promise at
        // the new answer position (CapTP § op:get "Receiving"); the engine
        // anchors the projection itself.
        .get => |get| try installAnswer(self, .inbound, get.answer),
        .index => |index| try installAnswer(self, .inbound, index.answer),
        .untag => |untag| try installAnswer(self, .inbound, untag.answer),
        else => {},
    }
}

/// The one inbound apply body for the kinds both recv representations carry
/// (`abort` / `deliver` / `resolve` / `start_session`). `anytype` over the
/// owned `model.Message` and the borrowed `model.view.Body`, exactly like the
/// validate walkers, so the two paths cannot drift. `introduced` is the far-
/// mention record the validate walk produced over this same message: apply
/// consumes it instead of re-walking the argument tree, so one inbound
/// deliver/resolve's argument bytes are traversed once, in validation.
fn applyRecvShared(self: *Session, message: anytype, introduced: *const validate.IntroducedImports) !void {
    switch (message) {
        .abort => self.close(),
        .deliver => |deliver| {
            if (deliver.answer) |answer| {
                try installAnswer(self, .inbound, answer);
            }
            // A `far` argument is the partner introducing one of its exports
            // as our import (ADR-0010); install every recorded mention so we
            // hold the import we were just handed (capability-passing + V1.0
            // resolver-callback fulfill payloads), each repeat a wire-delta
            // refresh. Validation already proved the import cap holds, so
            // `registerImport` can only fail on OOM (fatal by contract).
            try installIntroducedImports(self, introduced);
        },
        .resolve => |resolve| {
            if (self.outbound_answers.getPtr(resolve.answer)) |cell| {
                if (cell.status() == .pending) {
                    switch (resolve.resolution) {
                        .fulfill => cell.fulfill() catch unreachable,
                        .@"break" => cell.breakCell() catch unreachable,
                    }
                }
            }
            // A canonical `op:resolve` fulfilling with a `far` reference hands
            // us a new import (the resolved capability), install the recorded
            // mentions exactly as the deliver arm does.
            try installIntroducedImports(self, introduced);
        },
        .start_session => |ss| {
            // Learn the partner's session key and location (duped into
            // `key_arena`: a borrowed view's wire bytes don't outlive this
            // call, and an owned message is freed by its caller). Recorded
            // before the state transition so a failure leaves the handshake
            // unmarked. When the decode path supplies verbatim location
            // bytes, that buffer is the sole owner; the designator is a
            // relocated view into it (Syrup/Cap'n Proto borrow designator
            // from inside the location record). Owned-apply has no raw
            // bytes and keeps a designator-only dupe.
            const pubkey = sessionPubkeyBytes(ss);
            if (pubkey.len > 0) {
                self.partner_session_key = try self.key_arena.allocator().dupe(u8, pubkey);
            }
            if (acceptableLocationRawBytes(ss)) |raw| {
                if (raw.len > 0) {
                    const owned_raw = try self.key_arena.allocator().dupe(u8, raw);
                    self.partner_acceptable_location_raw = owned_raw;
                    if (ss.acceptable_location.designator.len > 0) {
                        if (relocateSubslice(owned_raw, raw, ss.acceptable_location.designator)) |des| {
                            self.partner_designator = des;
                        } else {
                            self.partner_designator = try self.key_arena.allocator().dupe(u8, ss.acceptable_location.designator);
                        }
                    }
                }
            } else if (ss.acceptable_location.designator.len > 0) {
                self.partner_designator = try self.key_arena.allocator().dupe(u8, ss.acceptable_location.designator);
            }
            self.partner_preference = try validate.parsePreferenceHints(ss.acceptable_location.hints);
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

/// When `child` is a subslice of `parent`, return the matching span inside
/// `owned` (same length, same relative offset). Used to keep
/// `partner_designator` as a view into the one owned location-record buffer.
fn relocateSubslice(owned: []u8, parent: []const u8, child: []const u8) ?[]const u8 {
    if (child.len == 0 or child.len > parent.len) return null;
    const parent_start = @intFromPtr(parent.ptr);
    const child_start = @intFromPtr(child.ptr);
    if (child_start < parent_start) return null;
    const off = child_start - parent_start;
    if (off + child.len > parent.len) return null;
    return owned[off..][0..child.len];
}

pub fn applySend(self: *Session, message: model.Message) !void {
    // Answer-producing sends retain every near reference they publish. Acquire
    // the only fallible storage those arms need before taking any wire-delta
    // retain, so an allocator refusal cannot leave authority for a frame that
    // never committed. validateSend already proved the position is fresh.
    const produced_answer: ?model.AnswerPosition = switch (message) {
        .deliver => |deliver| deliver.answer,
        .get => |get| get.answer,
        .index => |index| index.answer,
        .untag => |untag| untag.answer,
        else => null,
    };
    if (produced_answer != null)
        try self.outbound_answers.ensureUnusedCapacity(self.allocator, 1);

    // Account every `near` export we put on the wire so a later
    // `op:gc-exports` releasing the same wire-delta balances (see
    // `retainSentExports`).
    try retainSentExports(self, message);
    switch (message) {
        .deliver => |deliver| {
            if (deliver.answer) |answer| {
                installPreparedOutboundAnswer(self, answer);
            }
        },
        // Sending `op:get` / `op:index` / `op:untag` allocates the projected
        // answer on our side (ADR-0050): install it outbound so the partner's
        // `op:resolve` for it validates as an answer we are owed.
        .get => |get| installPreparedOutboundAnswer(self, get.answer),
        .index => |index| installPreparedOutboundAnswer(self, index.answer),
        .untag => |untag| installPreparedOutboundAnswer(self, untag.answer),
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
                const import_id = model.ImportPosition.from(pos);
                if (!self.imports.contains(import_id)) {
                    // A sturdyref cache row is useful only while its import
                    // row keeps that wire position's meaning alive. Once the
                    // count reaches zero the partner may reuse the position,
                    // so every swissnum that named it must enliven afresh.
                    self.forgetSturdyrefEnlivenmentsAt(import_id);
                    if (self.shorteningIncarnationForImport(import_id)) |source|
                        self.releaseShorteningSourceAuthority(source);
                }
            }
        },
        // Outbound `op:gc-answers` releases a question we asked — decrement
        // our outbound answers and drop any outbound resolver link we
        // committed for it.
        .gc_answer => |gc_answer| try applyGcAnswerDecrementOutbound(self, gc_answer.positions),
        .start_session => |ss| {
            // Record our own key before the transition: an exporter derives the
            // session name a handoff receive must carry from it (ADR-0009), and
            // both steps here are fallible, so the whole arm stays atomic by
            // doing the dupe first and flipping state last.
            const pubkey = sessionPubkeyBytes(ss);
            if (pubkey.len > 0) {
                self.local_session_key = try self.key_arena.allocator().dupe(u8, pubkey);
            }
            // Transition before setting local_sent so a failed bootstrap
            // install leaves the handshake unmarked.
            if (self.handshake_remote_received) try self.transitionToOpen();
            self.handshake_local_sent = true;
        },
        // No send-side table mutation beyond the `retainSentExports` accounting
        // above: `op:listen` anchors at the engine seam, and `op:abort` records
        // here without closing
        // — CapTP close (when required) is `Peer.commitAbortOutbound` after the
        // frame is on `outbound`, so the partner can still take it. Listing
        // them explicitly (rather
        // than `else`) makes a new `model.Message` kind fail to compile until
        // its apply decision is classified here.
        .listen, .abort => {},
    }
}

fn installPreparedOutboundAnswer(self: *Session, position: model.AnswerPosition) void {
    std.debug.assert(!self.outbound_answers.contains(position));
    self.outbound_answers.putAssumeCapacity(
        position,
        session.AnswerCell.initPending(position, self.nextStoreStamp()),
    );
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
/// is now structural: for every inbound answer, `status != .pending` if and
/// only if a resolution is stored.
pub fn applySentResolve(self: *Session, resolve: model.Resolve) !void {
    // Only V1.0 sends this resolution itself. Next stores settlement locally
    // and accounts an export mention if and when a listener callback carrying
    // it is queued.
    if (self.captp_version == .v1_0) {
        retainSentExports(self, .{ .resolve = resolve }) catch |err| {
            model.freeResolution(self.allocator, resolve.resolution);
            return err;
        };
    } else if (resolve.resolution == .fulfill) {
        recordSentExportArg(self, resolve.resolution.fulfill, 0, false) catch |err| {
            model.freeResolution(self.allocator, resolve.resolution);
            return err;
        };
    }
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

pub fn applyRecv(self: *Session, message: model.Message, introduced: *const validate.IntroducedImports) !void {
    switch (message) {
        .gc_export => |gc_export| {
            try session.applyGcExportDecrement(&self.exports, gc_export);
            for (gc_export.positions) |position|
                self.releaseShorteningResolverExport(model.ExportPosition.from(position));
        },
        // Inbound `op:gc-answers` releases an answer we created for the
        // partner, decrement our inbound answers and prune the inbound
        // resolver link we recorded for it.
        .gc_answer => |gc_answer| try applyGcAnswerDecrementInbound(self, gc_answer.positions),
        // `op:get` / `op:index` / `op:untag` export a promise at the new answer
        // position (CapTP § op:get "Receiving"): install the inbound answer the
        // partner will pipeline against. The engine anchors the projection
        // itself.
        .get => |get| try installAnswer(self, .inbound, get.answer),
        .index => |index| try installAnswer(self, .inbound, index.answer),
        .untag => |untag| try installAnswer(self, .inbound, untag.answer),
        // abort / deliver / resolve / start_session share one body with the
        // borrowed-view path.
        else => try applyRecvShared(self, message, introduced),
    }
}

/// Install the imports the validate walk recorded for this message (a
/// deliver's args or a resolution's fulfill payload). Each recorded mention is
/// a `<desc:import-object>` naming one of the partner's exports; registering
/// it records the import the session holds. The bootstrap import (0) was
/// excluded at record time; an already-held position increments its
/// wire-delta refcount, so a later `op:gc-exports` releasing the same total
/// delta balances. Consuming the record — instead of re-walking the argument
/// tree — is what keeps one inbound message's argument bytes to a single
/// traversal; the walk that produced it lives in
/// `validate.validateInboundArgument`, the one dual-shape walker.
fn installIntroducedImports(self: *Session, introduced: *const validate.IntroducedImports) RecvViewError!void {
    for (introduced.mentions.items) |import_position| {
        try self.registerImport(import_position);
    }
}

/// Retain a wire reference for every `near` export this outbound message
/// puts on the wire — the outbound mirror of `installIntroducedImports`.
/// Each time we name one of our exports the partner gains a reference it
/// will later release with a matching `op:gc-exports` wire-delta, so each
/// mention must increment the export's refcount; otherwise a partner that
/// received an export N times and releases with delta N underflows our
/// table and spuriously aborts the session. Every export row obeys one
/// contract: its count is the local baseline (`allocateExport` /
/// `reserveExport`) plus the wire references and explicit grants on top,
/// which is what makes `ExportTable.wireHeld` — the most an inbound
/// `op:gc-exports` may release — well-defined. The partner's GC can drive
/// the count down to the baseline but never below, so a fully-released
/// export survives for re-export rather than being dropped mid-session, and
/// these retains are also the *grant*: a reserved export becomes addressable
/// the moment its first mention crosses the wire (ADR-0074). The
/// bootstrap export (0) is permanent and excluded, symmetric with the
/// import-side bootstrap exclusion. Runs in apply, after `validateSend` has
/// proven every `near` on a deliver/listen/projection is a held export. A
/// resolve's fulfill `near` is the exception: resolving an answer with a
/// `.near` is how the application first exports that object, so the retain
/// mints the row here — baseline plus the mention, `registerExport`-shaped —
/// rather than finding one validation already proved.
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
        .gc_export, .gc_answer, .start_session, .abort => {},
    }
}

/// Retain the wire mention of one sent export reference. Public because the
/// engine's V1.0 resolver augmentation
/// (`engine.v1_0.prepareOutboundDeliver`) puts a resolver mention
/// on the wire at encode time, bypassing `recordSend`, and must take the same
/// wire-delta retain this apply walk would have added.
pub fn retainSentExportRef(self: *Session, reference: model.Reference) !void {
    switch (reference) {
        .near => |near| if (near.export_position.int() != BOOTSTRAP_POSITION) {
            try establishSentExportRef(self, near);
            // A live row's cell is authoritative from its establishment — an
            // authoritative promise mint (`allocatePromiseExport`), an object
            // reservation (`allocateExport`), or the first-mention branch above.
            // A re-mention only takes the wire-delta retain; it never rebinds
            // the cell from `near.kind`. The wire descriptor for an app export
            // is carried on the marshaled reference (the C-ABI sub_kind), not
            // derived from the row here, so the render path, which projects the
            // cell only for the session's own resolver exports — cannot read a
            // cell a later mention silently changed (ADR-0080).
            try self.exports.retain(self.allocator, near.export_position);
        },
        else => {},
    }
}

fn establishSentExportRef(self: *Session, near: model.NearRef) !void {
    if (near.export_position.int() == BOOTSTRAP_POSITION or self.exports.contains(near.export_position)) return;
    // A resolution may establish an export before next puts it on the wire.
    // Establish the local baseline separately from wire-delta accounting so a
    // later listener callback can retain exactly its own mention.
    try self.admitExportPositionForMarshal(near.export_position);
    const cell: slot.Slot = switch (near.kind) {
        .object => .{ .local_value = near.export_position.int() },
        .promise => .{ .local_unresolved = near.export_position.int() },
    };
    try self.exports.registerCell(self.allocator, near.export_position, cell);
}

fn retainSentExportArgs(self: *Session, args: []const model.Argument, depth: usize) RecvViewError!void {
    return recordSentExportArgs(self, args, depth, true);
}

fn retainSentExportArg(self: *Session, arg: model.Argument, depth: usize) RecvViewError!void {
    return recordSentExportArg(self, arg, depth, true);
}

fn recordSentExportArgs(self: *Session, args: []const model.Argument, depth: usize, wire_mention: bool) RecvViewError!void {
    if (depth > self.limits.max_nesting_depth) return Error.NestingTooDeep;
    for (args) |arg| try recordSentExportArg(self, arg, depth, wire_mention);
}

fn recordSentExportArg(self: *Session, arg: model.Argument, depth: usize, wire_mention: bool) RecvViewError!void {
    switch (arg) {
        .reference => |reference| switch (reference) {
            .near => |near| if (wire_mention)
                try retainSentExportRef(self, reference)
            else
                try establishSentExportRef(self, near),
            else => {},
        },
        .list, .set => |items| try recordSentExportArgs(self, items, depth + 1, wire_mention),
        .tagged => |tagged| try recordSentExportArgs(self, tagged.value, depth + 1, wire_mention),
        .@"struct" => |entries| {
            if (depth + 1 > self.limits.max_nesting_depth) return Error.NestingTooDeep;
            for (entries) |entry| try recordSentExportArg(self, entry.value, depth + 1, wire_mention);
        },
        // Exhaustive on purpose: a new Argument arm must decide here whether it
        // can name an export, see `validate.validateInboundArgument`.
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error", .handoff => {},
    }
}

/// Preallocate the export-table rows a validated stored resolution can first
/// establish when its listener fires are committed. Counting mentions rather
/// than distinct positions may overreserve, but keeps preparation allocation-
/// free and makes every later `applySend` infallible after authority moves.
pub fn ensureSentResolutionExportCapacity(self: *Session, resolution: model.Resolution) !void {
    const mentions = switch (resolution) {
        .fulfill => |arg| countNearMentions(arg),
        .@"break" => 0,
    };
    try self.exports.ensureUnusedCapacity(self.allocator, mentions);
}

fn countNearMentions(arg: model.Argument) usize {
    return switch (arg) {
        .reference => |reference| @intFromBool(reference == .near and reference.near.export_position.int() != session.BOOTSTRAP_POSITION),
        .list, .set => |items| blk: {
            var count: usize = 0;
            for (items) |item| count +|= countNearMentions(item);
            break :blk count;
        },
        .tagged => |tagged| blk: {
            var count: usize = 0;
            for (tagged.value) |item| count +|= countNearMentions(item);
            break :blk count;
        },
        .@"struct" => |entries| blk: {
            var count: usize = 0;
            for (entries) |entry| count +|= countNearMentions(entry.value);
            break :blk count;
        },
        .bytes, .symbol, .string, .keyword, .integer, .big_integer, .boolean, .float64, .void, .@"error", .handoff => 0,
    };
}

/// Apply `op:gc-answers` to our inbound answers. A fully-released answer can
/// never resolve again, so its V1.0 inbound resolver link (ADR-0010) is dropped
/// with the row. Both directions of the link go together: the forward map keyed
/// by answer and its inverse keyed by resolver-import, so neither outlives the
/// answer they describe. Two O(1) keyed removals.
fn applyGcAnswerDecrementInbound(self: *Session, positions: []const u64) Error!void {
    for (positions) |position| {
        if (try decrementAnswer(self, &self.inbound_answers, model.AnswerPosition.from(position))) {
            // Drop the whole link (both directions) with the answer it describes.
            _ = self.v1_0_inbound_resolver_link.removeByKey(model.AnswerPosition.from(position));
        }
    }
}

/// Apply `op:gc-answers` to our outbound answers. A fully-released answer is no
/// longer application-addressable, so its resolver-export link (ADR-0010,
/// ADR-0095) is retired with the row. The tombstone keeps a callback already in flight from
/// becoming an ordinary application deliver, and keeps the resolver export's
/// local baseline until the partner releases its wire mention. Converged
/// settling followers unlink or promote through answer back-links, so a client
/// releasing Q answers pays O(Q), not a scan of every imported promise.
fn applyGcAnswerDecrementOutbound(self: *Session, positions: []const u64) Error!void {
    for (positions) |position| {
        const answer = model.AnswerPosition.from(position);
        const entry = self.outbound_answers.getPtr(answer) orelse return Error.GcUnderflow;
        const final_release = entry.count == 1;
        const retired_state: session.RetiredResolverState = if (entry.status() == .pending)
            .pending
        else
            .complete;
        const settling_source = if (final_release)
            self.unlinkPromiseSettlingAnswer(answer)
        else
            null;
        if (!try decrementAnswer(self, &self.outbound_answers, answer)) continue;
        self.retireApplicationResolver(answer, retired_state, settling_source);
    }
}

/// Decrement an answer's refcount, removing it at zero. Returns whether the
/// answer was fully released (count reached zero). Releasing an answer frees
/// any queued pipelined calls, listeners, and stored resolution it owns.
fn decrementAnswer(self: *Session, table: *AnswerTable, position: model.AnswerPosition) Error!bool {
    const entry = table.getPtr(position) orelse return Error.GcUnderflow;
    if (entry.count == 0) return Error.GcUnderflow;
    entry.count -= 1;
    if (entry.count == 0) {
        session.deinitAnswerCell(self.allocator, entry);
        table.remove(position);
        return true;
    }
    return false;
}

/// Install a pending answer row in the table `direction` names. Inbound rows
/// are partner-named and capped by `SessionLimits.max_inbound_answers`;
/// outbound rows are positions we allocate, bounded by our own sends, so the
/// cap is the direction's policy, not a property of which pointer was passed.
/// Idempotent only for a still-pending inbound row: the engine installs a
/// queued pipelined call's answer at queue time and again at redirect time.
/// Outbound rows are locally chosen question identities and must always be
/// fresh.
pub fn installAnswer(self: *Session, direction: AnswerDirection, position: model.AnswerPosition) !void {
    const table = switch (direction) {
        .inbound => &self.inbound_answers,
        .outbound => &self.outbound_answers,
    };
    if (table.getPtr(position)) |entry| {
        if (direction == .outbound or entry.status() != .pending) return Error.UnexpectedMessage;
        return;
    }
    if (direction == .inbound and table.len() >= self.limits.max_inbound_answers) {
        return Error.InboundAnswerCapExceeded;
    }
    try table.put(self.allocator, position, session.AnswerCell.initPending(position, self.nextStoreStamp()));
}
