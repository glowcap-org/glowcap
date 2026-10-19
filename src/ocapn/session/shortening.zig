//! Private next-profile promise-shortening subscriptions.
//!
//! These listeners are protocol maintenance, not application questions. Their
//! resolver exports carry a shortening purpose rather than an answer: a
//! callback advances an imported promise's forwarding target and never
//! surfaces a synthetic application answer.
//!
//! The advanced target also decides where the next outbound message is
//! addressed: `rewriteMessage` runs at the send chokepoint, so a deliver the
//! application aimed at the source promise leaves naming the shortened one.
//! That is the local half of the end-to-end reference FIFO order OCapN PR 281
//! asks to survive shortening: every edge in this forest names an import on
//! *this* session, so both the earlier and the later deliver leave on one wire
//! in send order. An edge that named another session would put the two messages
//! on two wires and lose that. Nothing here can build one.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;

pub const Nomination = struct {
    source: model.ImportPosition,
    incarnation: session.PromiseIncarnation,
    resolver_export: model.ExportPosition,
    owns_metadata: bool,
};

pub const CallbackState = union(enum) {
    pending: session.PromiseIncarnation,
    complete,
};

/// Reserve one private resolver for `source`. Null means this promise
/// incarnation already has its one shortening subscription.
pub fn nominate(self: *Session, source: model.ImportPosition) !?Nomination {
    const owns_metadata = self.findImportedPromise(source) == null;
    if (owns_metadata) {
        try self.imported_promises.put(self.allocator, source, .{
            .row_id = self.nextStoreStamp(),
            .shortening_target = source,
        });
    }
    errdefer if (owns_metadata) {
        // The `put` above created the row in this dispatch, so its undo
        // cannot miss.
        var removed = self.imported_promises.fetchRemove(source) orelse unreachable;
        session.deinitImportedPromise(self.allocator, &removed.value);
    };
    const entry = self.findImportedPromise(source).?;
    if (entry.shortening_subscribed) return null;
    const incarnation: session.PromiseIncarnation = .{
        .position = source,
        .row_id = entry.row_id,
    };
    const resolver_export = try self.allocateExport();
    self.exports.setPurpose(resolver_export, .{ .shortening_pending = incarnation });
    entry.shortening_subscribed = true;
    return .{
        .source = source,
        .incarnation = incarnation,
        .resolver_export = resolver_export,
        .owns_metadata = owns_metadata,
    };
}

pub fn sourceIsHeld(self: *const Session, resolver: model.ExportPosition) bool {
    const purpose = self.exports.purpose(resolver) orelse return false;
    const source = switch (purpose) {
        .shortening_pending => |source| source,
        .shortening_complete => |source| source,
        .none, .forwarding, .application_answer, .local_promise_answer, .node_settling, .retired => return false,
    };
    return incarnationIsHeld(self, source);
}

pub fn abandon(self: *Session, nomination: Nomination) void {
    std.debug.assert(self.exports.clearPurpose(nomination.resolver_export) != null);
    if (nomination.owns_metadata) {
        // `nominate` recorded `owns_metadata` beside the `put` that created
        // the row, so the undo cannot miss.
        const removed = self.imported_promises.fetchRemove(nomination.source) orelse unreachable;
        var entry = removed.value;
        session.deinitImportedPromise(self.allocator, &entry);
    } else {
        // `nominate` set the flag on this incarnation's entry in this
        // dispatch, so the undo cannot miss.
        const entry = currentEntry(self, nomination.incarnation) orelse unreachable;
        entry.shortening_subscribed = false;
    }
    self.releaseUnsharedExport(nomination.resolver_export);
}

pub fn sourceForResolver(self: *const Session, resolver: model.ExportPosition) ?CallbackState {
    const purpose = self.exports.purpose(resolver) orelse return null;
    return switch (purpose) {
        .shortening_pending => |source| .{ .pending = source },
        .shortening_complete => .complete,
        // `resolver` is a partner-named position, so this probe answers one
        // question: is it a shortening resolver? It returns null for every
        // other purpose; the deliver route reads the purpose itself and the
        // other probes (`retiredResolverState`, `answerForResolverExport`)
        // each answer their own. Only the mint discipline keeps an answer
        // purpose off a resolver key, and that discipline holds across
        // dispatches, so the null return is the safe answer to a mint bug or
        // a probing partner.
        .none, .forwarding, .application_answer, .local_promise_answer, .node_settling, .retired => null,
    };
}

/// Validate a proposed link without mutating the forest. Following self-roots
/// includes pending targets and detects a partner-proposed cycle in bounded
/// time. Every existing non-self link was admitted by this same check.
/// The deliver route classifier reaches here only after
/// `sourceForShorteningResolver` saw this resolver's pending purpose in the
/// same dispatch, so the read below can assert presence and a shortening
/// purpose rather than refuse a partner-named position.
pub fn validateCompletion(self: *const Session, resolver: model.ExportPosition, target: model.FarRef) session.Error!void {
    const purpose = self.exports.purpose(resolver) orelse unreachable;
    const source = switch (purpose) {
        .shortening_pending => |incarnation| incarnation,
        .shortening_complete => return error.UnexpectedMessage,
        .none, .forwarding, .application_answer, .local_promise_answer, .node_settling, .retired => unreachable,
    };
    if (!incarnationIsCurrent(self, source)) return;
    var current = target.import_position;
    var remaining = self.imported_promises.count() + 1;
    while (remaining != 0) : (remaining -= 1) {
        if (current == source.position) return error.UnexpectedMessage;
        const entry = self.imported_promises.get(current) orelse return;
        const next = entry.shortening_target;
        if (next == current) return;
        current = next;
    }
    return error.UnexpectedMessage;
}

/// Commit a validated callback. Both rows already exist, so this is
/// allocation-free and cannot strand an applied import introduction halfway.
///
/// The callback's deliver introduced `target`, and that one retain has one
/// of two owners. While the source is still held the edge is stable and
/// keeps it (`edge_owns_retain`): the session adopts it here and spends it
/// through the closure `expandGcExportReleases` adds to the release that
/// finally drops the source. A source already released leaves the edge no
/// reason to exist, and the engine releases the retain in the same
/// transaction instead.
pub fn complete(self: *Session, resolver: model.ExportPosition, target: model.FarRef, edge_owns_retain: bool) void {
    const purpose = self.exports.purpose(resolver) orelse unreachable;
    const source = switch (purpose) {
        .shortening_pending => |incarnation| incarnation,
        // `complete` runs only behind `validateCompletion`, which refuses a
        // non-pending purpose and asserts presence in the same dispatch.
        else => unreachable,
    };
    if (incarnationIsCurrent(self, source)) {
        const entry = self.findImportedPromise(source.position).?;
        entry.shortening_target = target.import_position;
        entry.shortening_target_retained = edge_owns_retain;
        if (edge_owns_retain) self.adoptImportRetain(target.import_position);
    }
    _ = self.exports.replacePurpose(resolver, .{ .shortening_complete = source });
}

/// Release source-owned state after its final import retain disappears. The
/// entry goes unless a settling listener still claims it. A shortening
/// resolver's purpose stays on its export row until the partner releases
/// the mention, and names an incarnation no row holds from then on.
pub fn releaseSourceAuthority(self: *Session, source: session.PromiseIncarnation) void {
    std.debug.assert(!incarnationIsHeld(self, source));
    const entry = currentEntry(self, source) orelse return;
    if (entry.settling_listener_claimed) return;
    // `currentEntry` above found the row in this dispatch, so its undo
    // cannot miss.
    const removed = self.imported_promises.fetchRemove(source.position) orelse unreachable;
    var removed_entry = removed.value;
    session.deinitImportedPromise(self.allocator, &removed_entry);
}

/// The partner released its shortening resolver mention. A pending listener
/// therefore concluded without a shortening callback. The entry's
/// `shortening_subscribed` flag outlives the export while the source import
/// remains, so a later mention cannot install a second shortening listener
/// for the same promise.
pub fn releaseResolverExport(self: *Session, resolver: model.ExportPosition) void {
    @import("forwarding.zig").releaseIfUnmentioned(self, resolver);
    const purpose = self.exports.purpose(resolver) orelse return;
    const source = switch (purpose) {
        .retired => {
            self.releaseRetiredResolverIfUnmentioned(resolver);
            return;
        },
        .shortening_pending, .shortening_complete => |incarnation| incarnation,
        .none, .forwarding, .application_answer, .local_promise_answer, .node_settling => return,
    };
    if (self.exports.wireHeld(resolver) != 0) return;

    self.releaseUnsharedExport(resolver);
    if (!incarnationIsHeld(self, source)) {
        if (incarnationIsCurrent(self, source)) {
            if (!self.findImportedPromise(source.position).?.settling_listener_claimed) {
                if (self.imported_promises.fetchRemove(source.position)) |removed| {
                    var entry = removed.value;
                    session.deinitImportedPromise(self.allocator, &entry);
                }
            }
        }
    }
}

pub fn incarnationForImport(self: *Session, position: model.ImportPosition) ?session.PromiseIncarnation {
    const entry = self.findImportedPromise(position) orelse return null;
    return .{ .position = position, .row_id = entry.row_id };
}

fn currentEntry(self: *Session, source: session.PromiseIncarnation) ?*session.ImportedPromise {
    const entry = self.findImportedPromise(source.position) orelse return null;
    return if (entry.row_id == source.row_id) entry else null;
}

fn incarnationIsCurrent(self: *const Session, source: session.PromiseIncarnation) bool {
    const entry = self.imported_promises.get(source.position) orelse return false;
    return entry.row_id == source.row_id;
}

fn incarnationIsHeld(self: *const Session, source: session.PromiseIncarnation) bool {
    return incarnationIsCurrent(self, source) and self.imports.contains(source.position);
}

const ReleaseState = struct {
    total: u64 = 0,
    processed: bool = false,
};

/// Closure scratch keyed by peer-chosen import positions (ADR-0037). A
/// closure of a few positions stays inline.
const ReleaseStates = foundation.inline_rows.Table(model.ImportPosition, ReleaseState, 8, .wire);

/// Whether any released position is a shortening source whose stable edge
/// owns a retain, the only shape that gives a release a closure.
fn namesRetainedShorteningSource(self: *const Session, positions: []const u64) bool {
    if (self.imported_promises.count() == 0) return false;
    for (positions) |raw_position| {
        if (retainedShorteningTarget(self, .from(raw_position)) != null) return true;
    }
    return false;
}

/// Extend one owned outbound GC operation with the import retains held by
/// stable shortening edges whose sources this operation releases in full. The
/// closure matters for chains: releasing 5 may release the edge-owned retain
/// of 6, which can in turn release the edge-owned retain of 7.
///
/// This runs before `recordSend`, so all fallible scratch and replacement
/// storage is acquired before any import count or shortening metadata changes.
/// The caller's entries stay first and are bounded by `releasable` as
/// `recordSend` will bound them. The closure's entries trail them and are the
/// session's own, adopted at `complete` and applied through
/// `recordSessionImportRelease`. Returns how many trailing entries the closure
/// added: zero, with nothing allocated, for the ordinary release of a promise
/// nothing shortened to.
pub fn expandGcExportReleases(
    self: *Session,
    allocator: std.mem.Allocator,
    gc_export: *model.GcExport,
) !usize {
    return expandGcExportReleasesOwned(self, allocator, gc_export, false);
}

pub fn expandSessionGcExportReleases(self: *Session, allocator: std.mem.Allocator, gc_export: *model.GcExport) !usize {
    return expandGcExportReleasesOwned(self, allocator, gc_export, true);
}

fn expandGcExportReleasesOwned(self: *Session, allocator: std.mem.Allocator, gc_export: *model.GcExport, session_owned: bool) !usize {
    try session.validateGcExport(gc_export.*);
    // `recordSend` owns every bound on the caller's entries, so an ordinary
    // release returns here with nothing allocated.
    if (!namesRetainedShorteningSource(self, gc_export.positions)) return 0;

    var states: ReleaseStates = .keyed(self.wire_hash_multiplier);
    defer states.deinit(allocator);
    var queue: std.ArrayListUnmanaged(model.ImportPosition) = .empty;
    defer queue.deinit(allocator);
    var extra: std.ArrayListUnmanaged(model.ImportPosition) = .empty;
    defer extra.deinit(allocator);

    for (gc_export.positions, gc_export.deltas) |raw_position, delta| {
        const position = model.ImportPosition.from(raw_position);
        const gop = try states.getOrPut(allocator, position);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.total = std.math.add(u64, gop.value_ptr.total, delta) catch
            return error.GcUnderflow;
    }

    var state_it = states.iterator();
    while (state_it.next()) |entry| {
        if (entry.value_ptr.total > (if (session_owned) self.imports.sessionHeld(entry.key_ptr.*) else self.imports.releasable(entry.key_ptr.*))) return error.GcUnderflow;
        if (entry.value_ptr.total == self.imports.count(entry.key_ptr.*) and retainedShorteningTarget(self, entry.key_ptr.*) != null)
            try queue.append(allocator, entry.key_ptr.*);
    }

    while (queue.pop()) |source| {
        // The queue above was built from this same `states` table, so every
        // drained key is present.
        const source_state = states.getPtr(source) orelse unreachable;
        if (source_state.processed) continue;
        source_state.processed = true;
        const target = retainedShorteningTarget(self, source) orelse continue;
        try extra.append(allocator, target);

        const gop = try states.getOrPut(allocator, target);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.total = std.math.add(u64, gop.value_ptr.total, 1) catch
            return error.GcUnderflow;
        // The caller's entries on `target` were bounded by `releasable` above,
        // and every retained edge into it adopted one retain at `complete`,
        // so the running total cannot pass the row's count.
        const held = self.imports.count(target);
        std.debug.assert(gop.value_ptr.total <= held);
        if (gop.value_ptr.total == held and retainedShorteningTarget(self, target) != null)
            try queue.append(allocator, target);
    }

    if (extra.items.len == 0) return 0;

    // The queue owns both slices until encode. Replacement is the one durable
    // allocation the synthesized wire release requires; all maps/lists above
    // are turn scratch and die before this function returns.
    const expanded_len = gc_export.positions.len + extra.items.len;
    const positions = try allocator.alloc(u64, expanded_len);
    errdefer allocator.free(positions);
    const deltas = try allocator.alloc(u64, expanded_len);
    errdefer allocator.free(deltas);
    @memcpy(positions[0..gc_export.positions.len], gc_export.positions);
    @memcpy(deltas[0..gc_export.deltas.len], gc_export.deltas);
    for (extra.items, positions[gc_export.positions.len..], deltas[gc_export.deltas.len..]) |target, *position, *delta| {
        position.* = target.int();
        delta.* = 1;
    }

    allocator.free(gc_export.positions);
    allocator.free(gc_export.deltas);
    gc_export.* = .{ .positions = positions, .deltas = deltas };
    return extra.items.len;
}

/// The stable edge out of `source` whose retain the session owns: the only
/// kind the closure on `source`'s final release may spend. Routing follows
/// every edge. Spending follows this one.
fn retainedShorteningTarget(self: *const Session, source: model.ImportPosition) ?model.ImportPosition {
    const entry = self.imported_promises.get(source) orelse return null;
    if (!entry.shortening_target_retained or entry.shortening_target == source) return null;
    return entry.shortening_target;
}

fn rewriteReference(self: *Session, reference: model.Reference) model.Reference {
    if (reference != .far or reference.far.kind != .promise) return reference;
    const source = reference.far.import_position;
    var current = source;
    var remaining = self.imported_promises.count() + 1;
    while (remaining != 0) : (remaining -= 1) {
        const next = (self.findImportedPromise(current) orelse break).shortening_target;
        if (next == current) break;
        current = next;
    }
    if (current == source) return reference;
    // Do not path-compress this chain. Each stable edge also owns the one
    // import retain introduced by its callback; changing 5 -> 6 into 5 -> 7
    // would leak 6 and release a retain of 7 that edge never received.
    return .{ .far = model.FarRef.promise(current.int()) };
}

/// `rewriteMessage` for a resolution held outside a message. Shortening never
/// fails, so the walk's error set is empty and the switch proves it.
pub fn rewriteResolution(self: *Session, resolution: *model.Resolution, inventory: session.Inventory) void {
    session.inventory.mapResolutionReferences(resolution, inventory, self, rewriteReference) catch |err| switch (err) {};
}

/// Rewrite every far promise in one owned outbound message through the
/// authoritative shortening forest. POD references change in place. No heap is
/// allocated or copied.
pub fn rewriteMessage(self: *Session, message: *model.Message, inventory: session.Inventory) void {
    session.inventory.mapMessageReferences(message, inventory, self, rewriteReference) catch |err| switch (err) {};
}
