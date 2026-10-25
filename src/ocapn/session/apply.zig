//! Session apply: the "commit the message's effect" half of the state machine.
//!
//! The public spine is the three dispatch appliers (`applySend`, `applyRecv`,
//! `applyRecvView`), reached through `Session.recordSend` / `recordRecv` /
//! `recordRecvView`, plus the two commit steps the engine drives directly
//! (`retainSentExportRef`, `installInboundAnswerNamed`).
//! Recursive sent-export accounting lives in `apply/sent_exports.zig`. Appliers run
//! only after the matching validator in `validate.zig` has proven the message
//! valid, and they mutate the authoritative tables: installing answers,
//! retaining and releasing wire-delta refcounts, introducing imports, and
//! advancing the handshake. Apply stays all-or-nothing for every typed protocol
//! refusal: validation decides them before apply mutates (the
//! prospective-import cap walk in `validate.zig` exists for exactly this), and
//! the one refusal raised here, the cap in `installInboundAnswerNamed`,
//! fires as an arm's first step, before anything commits. Only a host
//! allocation failure can interrupt an arm mid-walk. The engine treats that as
//! fatal to the session, never as state to resume from.

const std = @import("std");
const model = @import("model");
const answers = @import("answers/store.zig");
const resolution_store = @import("answers/resolution_store.zig");
const listen_claims = @import("listen_claims.zig");
const sent_exports = @import("apply/sent_exports.zig");
const session = @import("mod.zig");
const validate = @import("validate.zig");

const Session = session.Session;
const Error = session.Error;
const bootstrap_position = session.bootstrap_position;
const RecvViewError = session.RecvViewError;

pub const retainSentExportRef = sent_exports.retainRef;
pub const releaseSentMessage = sent_exports.releaseMessage;
pub const releaseSentExports = sent_exports.releaseExports;
pub const listSentExports = sent_exports.listSentExports;
pub const ensureSentResolutionExportCapacity = sent_exports.ensureResolutionCapacity;

pub fn applyRecvView(self: *Session, body: *const model.view.Body, introduced: *const validate.IntroducedImports) !void {
    switch (body.*) {
        // The borrowed steady-state kinds share one apply body with the owned
        // retain path; the rarer owned-fallback kinds never arrive here (they
        // are routed through `recordRecv` by `recordRecvView`).
        .abort, .deliver, .resolve, .start_session => try applyRecvShared(self, body, introduced),
        // The owned dispatch's twin arms: a projection op exports a promise at
        // the new answer position (CapTP § op:get "Receiving"); the engine
        // anchors the projection itself.
        .get => |get| try installInboundAnswerNamed(self, .fromWire(get.answer)),
        .index => |index| try installInboundAnswerNamed(self, .fromWire(index.answer)),
        .untag => |untag| try installInboundAnswerNamed(self, .fromWire(untag.answer)),
        else => {},
    }
}

/// The one inbound apply body for the kinds both recv representations carry
/// (`abort` / `deliver` / `resolve` / `start_session`). `anytype` over the
/// owned `model.Message` and the borrowed `model.view.Body`, like the
/// validate walkers, so the two paths cannot drift. `introduced` is the far-
/// mention record the validate walk produced over this same message: apply
/// consumes it instead of re-walking the argument tree, so one inbound
/// deliver/resolve's argument bytes are traversed once, in validation.
/// `message` points at the owned or the borrowed message, so the deliver arm
/// reads its tree in place.
fn applyRecvShared(self: *Session, message: anytype, introduced: *const validate.IntroducedImports) !void {
    switch (message.*) {
        .abort => self.close(),
        .deliver => |*deliver| {
            if (deliver.answer) |answer| {
                try installInboundAnswerNamed(self, .fromWire(answer));
            }
            // A `far` argument is the partner introducing one of its exports
            // as our import (ADR-0006); install every recorded mention so we
            // hold the import we were just handed (capability-passing + V1.0
            // resolver-callback fulfill payloads), each repeat a wire-delta
            // refresh. Validation already proved the import cap holds, so
            // `registerImport` can only fail on OOM (fatal by contract).
            installIntroducedImports(self, introduced);
        },
        .resolve => |resolve| {
            if (self.outbound_answers.getPtr(resolve.answer)) |cell| {
                if (cell.status() == .pending) cell.settle(resolve.resolution);
            }
            // A canonical `op:resolve` fulfilling with a `far` reference hands
            // us a new import (the resolved capability), install the recorded
            // mentions as the deliver arm does.
            installIntroducedImports(self, introduced);
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
/// decode view (`?[]const u8`). The owned `model.StartSession` has no such field,
/// so the owned-apply path reports none.
fn acceptableLocationRawBytes(ss: anytype) ?[]const u8 {
    return if (comptime @hasField(@TypeOf(ss), "acceptable_location_raw"))
        ss.acceptable_location_raw
    else
        null;
}

/// When `child` is a subslice of `parent`, return the matching span inside
/// `owned` (same length, same relative offset). Used to keep status-allow: purpose clause
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

/// `resolver` is the resolver export an admitted deliver minted for its
/// answer before this record (`engine.outbound.encoded.admit`), which the
/// answer row installed here takes (ADR-0038). Null for every other send.
pub fn applySend(self: *Session, message: model.Message, inventory: session.Inventory, resolver: ?model.ExportPosition) !void {
    std.debug.assert(resolver == null or message == .deliver);
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
    if (produced_answer) |answer|
        try self.outbound_answers.ensureInstallable(self.allocator, answer);

    // Account every `near` export we put on the wire so a later
    // `op:gc-exports` releasing the same wire-delta balances.
    try sent_exports.retainMessage(self, message, inventory);
    switch (message) {
        .deliver => |deliver| {
            if (deliver.answer) |answer| {
                installPreparedOutboundAnswer(self, answer, resolver);
                if (self.captp_version == .next)
                    self.outbound_answers.getPtr(answer).?.sent_listen_modes = @backingInt(deliver.listen_mode);
            }
        },
        // Sending `op:get` / `op:index` / `op:untag` allocates the projected
        // answer on our side (ADR-0004): install it outbound so the partner's
        // `op:resolve` for it validates as an answer we are owed.
        .get => |get| installPreparedOutboundAnswer(self, get.answer, null),
        .index => |index| installPreparedOutboundAnswer(self, index.answer, null),
        .untag => |untag| installPreparedOutboundAnswer(self, untag.answer, null),
        // A sent `op:resolve` is routed through `applySentResolve` by
        // `recordSend`, never here, it consumes the resolution (moves it into
        // the answer store) under a single-owner contract `applySend`'s
        // borrow-the-message shape cannot express.
        .resolve => unreachable,
        .gc_export => |gc_export| {
            try session.applyGcExportDecrement(&self.imports, gc_export);
            retireReleasedImports(self, gc_export.positions);
        },
        // Outbound `op:gc-answers` releases a question we asked, decrement
        // our outbound answers and retire the resolver export we bound to
        // each one.
        .gc_answer => |gc_answer| try applyGcAnswerDecrementOutbound(self, gc_answer.positions),
        .start_session => |ss| {
            // Record our own key before the transition: an exporter derives the
            // session name a handoff receive must carry from it (ADR-0039), and
            // both steps here are fallible, so the whole arm stays atomic by
            // doing the dupe first and flipping state last.
            const local_preference = try validate.parsePreferenceHints(ss.acceptable_location.hints);
            const pubkey = sessionPubkeyBytes(ss);
            if (pubkey.len > 0) {
                self.local_session_key = try self.key_arena.allocator().dupe(u8, pubkey);
            }
            // Transition before setting local_sent so a failed bootstrap
            // install leaves the handshake unmarked.
            if (self.handshake_remote_received) try self.transitionToOpen();
            self.local_preference = local_preference;
            self.handshake_local_sent = true;
        },
        // No send-side table mutation beyond export-retain accounting
        // above: `op:listen` anchors at the engine seam, and `op:abort` records
        // here without closing
        // CapTP close (when required) is `Peer.commitAbortOutbound` after the
        // frame is on `outbound`, so the partner can still take it. Listing
        // them explicitly (rather
        // than `else`) makes a new `model.Message` kind fail to compile until
        // its apply decision is classified here.
        .listen => |listen| listen_claims.record(self, listen),
        .abort => {},
    }
}

/// A position minted by `allocateOutboundAnswer` carries the stamp it was
/// reserved with, so the target the caller holds names the row installed
/// here. A position the caller chose is stamped now.
fn installPreparedOutboundAnswer(self: *Session, position: model.AnswerPosition, resolver: ?model.ExportPosition) void {
    std.debug.assert(!self.outbound_answers.contains(position));
    const stamp = self.outbound_answers.reservedStamp(position) orelse self.nextStoreStamp();
    var cell = session.AnswerCell.initPending(stamp);
    if (resolver) |resolver_export| cell.setResolverExport(resolver_export);
    self.outbound_answers.installAssumeCapacity(position, cell);
}

/// Apply a resolve we are sending. **Consumes `resolve.resolution`**: it is
/// moved into the inbound answer's store on success, or freed on any failure,
/// the caller never frees it (a resolve has no heap beyond its resolution). The
/// store becomes the single owner: the queued outbound carrier holds only the
/// answer position, and `Peer.step` reads the resolution back from the store to
/// encode (`mod.Outbound.settled_answer`).
///
/// Moving here, not cloning, is what closes the record/emit gap *and* keeps
/// the wire path copy-free: the status flip and the stored resolution are one
/// fact ("this inbound answer is settled, and here is its value"), so they land
/// together at record time. Storing only when the queued frame later emits split
/// them, opening a window, as wide as a whole inbound batch, since repeated
/// `Peer.step` calls drain queued inbound before emitting any outbound, in
/// which an answer read settled with no resolution on hand. Every
/// status-reading consumer (op:listen, projections, pipelined op:deliver) then
/// had to special-case it. The invariant is structural: for every inbound
/// answer, `status != .pending` if and only if a resolution is stored.
pub fn applySentResolve(self: *Session, resolve: model.Resolve, inventory: session.Inventory) !void {
    return applySentResolutionNamed(self, .fromWire(resolve.answer), resolve.resolution, inventory);
}

pub fn applySentResolutionNamed(
    self: *Session,
    answer_name: model.AnswerName,
    resolution: model.Resolution,
    inventory: session.Inventory,
) !void {
    // Admit the durable answer bytes before any capacity reservation or export
    // mutation. The inventory measured the tree once, and its charge travels
    // through the later infallible commit.
    const store_plan = resolution_store.planResolutionStoreNamed(self, answer_name, resolution, inventory.owned_bytes) catch |err| {
        model.freeResolution(self.allocator, resolution);
        return err;
    };
    // A V1 resolver callback is a known publication and takes its wire retain
    // in the commit; next keeps only the local baseline until each listener
    // fire takes its retain at queue time.
    const has_v1_callback = self.captp_version == .v1_0 and
        self.resolverForInboundAnswer(answer_name) != null;
    return commitSentResolution(self, store_plan, has_v1_callback, resolution, inventory);
}

pub fn applySentResolutionTarget(
    self: *Session,
    target: session.AnswerTarget,
    payload: *session.AnswerPayload,
    resolution: model.Resolution,
    inventory: session.Inventory,
) !void {
    const store_plan = resolution_store.planResolutionStoreTarget(self, target, payload, resolution, inventory.owned_bytes) catch |err| {
        model.freeResolution(self.allocator, resolution);
        return err;
    };
    const has_v1_callback = self.captp_version == .v1_0 and payload.resolver_import != null;
    return commitSentResolution(self, store_plan, has_v1_callback, resolution, inventory);
}

/// The commit both sent-resolution verbs share once their store is planned.
/// Owns `resolution` on every outcome: freed on a refusal, moved into the
/// store on success.
fn commitSentResolution(
    self: *Session,
    store_plan: resolution_store.ResolutionStorePlan,
    has_v1_callback: bool,
    resolution: model.Resolution,
    inventory: session.Inventory,
) !void {
    var resolution_owned = true;
    errdefer if (resolution_owned)
        model.freeResolution(self.allocator, resolution);
    // Reserve every allocation the export pass and answer store can need before
    // either authority changes. The inventory already bounded the tree;
    // capacity plus the prepared store make the commit below infallible.
    try self.ensureSentResolutionExportCapacity(resolution, inventory);
    const prepared_store = try resolution_store.prepareResolutionStore(self, store_plan);
    // Establish every fulfilled local export now.
    if (resolution == .fulfill) {
        sent_exports.recordMentions(self, inventory, &resolution.fulfill, has_v1_callback) catch unreachable;
    }
    // Transfer ownership only after every fallible preparation. No export
    // retain can survive without the stored resolution it describes.
    resolution_store.commitPreparedResolutionStore(self, prepared_store, resolution);
    resolution_owned = false;
}

pub fn applyRecv(self: *Session, message: model.Message, introduced: *const validate.IntroducedImports) !void {
    switch (message) {
        .gc_export => |gc_export| {
            try session.applyGcExportDecrement(&self.exports, gc_export);
            for (gc_export.positions) |position| {
                const export_position = model.ExportPosition.from(position);
                self.releaseRetiredResolverIfUnmentioned(export_position);
                self.releaseShorteningResolverExport(model.ExportPosition.from(position));
            }
            self.collectLocalPromiseProjections();
        },
        // Inbound `op:gc-answers` releases an answer we created for the
        // partner, decrement our inbound answers and prune the inbound
        // resolver link we recorded for it.
        .gc_answer => |gc_answer| try applyGcAnswerDecrementInbound(self, gc_answer.positions),
        // `op:get` / `op:index` / `op:untag` export a promise at the new answer
        // position (CapTP § op:get "Receiving"): install the inbound answer the
        // partner will pipeline against. The engine anchors the projection
        // itself.
        .get => |get| try installInboundAnswerNamed(self, .fromWire(get.answer)),
        .index => |index| try installInboundAnswerNamed(self, .fromWire(index.answer)),
        .untag => |untag| try installInboundAnswerNamed(self, .fromWire(untag.answer)),
        // abort / deliver / resolve / start_session share one body with the
        // borrowed-view path.
        else => try applyRecvShared(self, &message, introduced),
    }
}

/// Install the imports the validate walk recorded for this message (a
/// deliver's args or a resolution's fulfill payload). Each recorded mention is
/// a `<desc:import-object>` naming one of the partner's exports. Registering
/// it records the import the session holds. The bootstrap import (0) was
/// excluded at record time. An already-held position increments its
/// wire-delta refcount, so a later `op:gc-exports` releasing the same total
/// delta balances. Consuming the record, instead of re-walking the argument
/// tree, is what keeps one inbound message's argument bytes to a single
/// traversal. The walk that produced it is
/// `session/validate/passable.zig`'s one dual-shape walker.
fn installIntroducedImports(self: *Session, introduced: *const validate.IntroducedImports) void {
    for (introduced.mentions.items()) |import_position| {
        self.imports.retainAssumeCapacity(import_position);
    }
}

/// Apply the session's own outbound `op:gc-exports`: each entry spends
/// retains the session adopted for this release, so the decrement
/// cannot fail. The consequences of a row reaching zero are the caller
/// release's, unchanged.
pub fn applySessionImportRelease(self: *Session, gc_export: model.GcExport) void {
    for (gc_export.positions, gc_export.deltas) |pos, delta| {
        std.debug.assert(pos != bootstrap_position);
        self.imports.releaseSessionHeld(.from(pos), delta);
    }
    retireReleasedImports(self, gc_export.positions);
}

/// After an outbound release, retire whatever named a position whose import
/// row is gone. ADR-0039: a fully-released third-party import can never
/// receive a relayed resolution, so its imported-promise row (host, listeners,
/// stored resolution) goes with the import.
fn retireReleasedImports(self: *Session, positions: []const u64) void {
    for (positions) |pos| {
        const import_id = model.ImportPosition.from(pos);
        if (self.imports.contains(import_id)) continue;
        // A sturdyref cache row is useful only while its import row keeps
        // that wire position's meaning alive. Once the count reaches zero the
        // partner may reuse the position, so every swissnum that named it
        // must enliven afresh.
        self.forgetSturdyrefEnlivenmentsAt(import_id);
        if (self.shorteningIncarnationForImport(import_id)) |source|
            self.releaseShorteningSourceAuthority(source);
    }
    self.collectLocalPromiseProjections();
}

/// Apply `op:gc-answers` to the partner's pipelining ownership. A final
/// decrement releases and immediately frees the wire name for reuse. An
/// already-accepted resolver/listener obligation keeps the answer incarnation
/// alive under its private row stamp until that notification publishes.
fn applyGcAnswerDecrementInbound(self: *Session, positions: []const u64) !void {
    try self.prepareAnswerGc(positions);
    for (positions) |position| {
        const answer = model.AnswerName.fromWire(.from(position));
        const entry = self.inbound_answers.getPtr(answer) orelse return error.GcUnderflow;
        if (entry.count == 0) return error.GcUnderflow;
        if (entry.count == 1) self.commitFinalAnswerGc(answer) else entry.count -= 1;
    }
    self.collectLocalPromiseProjections();
}

/// Apply `op:gc-answers` to our outbound answers. A fully-released answer is no
/// longer application-addressable, so its resolver-export link (ADR-0006,
/// ADR-0003) is retired with the row. The tombstone keeps a callback already in flight from
/// becoming an ordinary application deliver, and keeps the resolver export's
/// local baseline until the partner releases its wire mention. Converged
/// settling followers unlink or promote through answer back-links, so a client
/// releasing Q answers pays O(Q), not a scan of every imported promise.
fn applyGcAnswerDecrementOutbound(self: *Session, positions: []const u64) Error!void {
    for (positions) |position| {
        const answer = model.AnswerPosition.from(position);
        try self.releaseOutboundAnswer(answer);
    }
}

/// Install a fresh pending outbound answer: a question identity we chose,
/// bounded by our own sends and so under no cap. A position already live is
/// refused.
pub fn installOutboundAnswer(self: *Session, position: model.AnswerPosition) !void {
    if (!self.outbound_answers.fresh(position)) return error.UnexpectedMessage;
    try self.outbound_answers.ensureInstallable(self.allocator, position);
    const stamp = self.outbound_answers.reservedStamp(position) orelse self.nextStoreStamp();
    self.outbound_answers.installAssumeCapacity(position, session.AnswerCell.initPending(stamp));
}

/// Install a pending inbound answer we owe resolution for. Inbound rows and
/// detached accepted consequences share `SessionLimits.max_inbound_answers`.
/// Idempotent for a still-pending row: validation and apply may meet the same
/// answer during one prepared receive transaction.
pub fn installInboundAnswerNamed(self: *Session, answer: model.AnswerName) !void {
    if (self.inbound_answers.getPtr(answer)) |entry| {
        if (entry.status() != .pending) return error.UnexpectedMessage;
        return;
    }
    if (self.inboundAnswersAtCap()) return error.InboundAnswerCapExceeded;
    try self.inbound_answers.put(
        self.allocator,
        answer,
        session.AnswerCell.initPending(self.nextStoreStamp()),
    );
}
