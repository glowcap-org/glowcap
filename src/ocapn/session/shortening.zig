//! Private next-profile promise-shortening subscriptions.
//!
//! These listeners are protocol maintenance, not application questions. Their
//! resolver exports therefore live in a distinct table from answer resolvers:
//! a callback advances an imported promise's forwarding target and never
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
            .host = null,
            .cell = .{ .row_id = self.nextStoreStamp() },
            .shortening_target = source,
        });
    }
    errdefer if (owns_metadata) {
        // The `put` above created the row in this dispatch, so its undo
        // cannot miss.
        var removed = self.imported_promises.fetchRemove(source) orelse unreachable;
        session.deinitImportedPromise(self.allocator, &removed.value);
    };
    const incarnation: session.PromiseIncarnation = .{
        .position = source,
        .row_id = self.findImportedPromise(source).?.cell.row_id,
    };
    if (self.outbound_resolver_link.getByValue(.{ .shortening_pending = incarnation }) != null or
        self.outbound_resolver_link.getByValue(.{ .shortening_complete = incarnation }) != null)
        return null;
    const resolver_export = try self.allocateExport();
    errdefer self.releaseUnsharedExport(resolver_export);
    try self.outbound_resolver_link.put(self.allocator, resolver_export, .{ .shortening_pending = incarnation });
    return .{
        .source = source,
        .incarnation = incarnation,
        .resolver_export = resolver_export,
        .owns_metadata = owns_metadata,
    };
}

pub fn sourceIsHeld(self: *const Session, resolver: model.ExportPosition) bool {
    const purpose = self.outbound_resolver_link.getByKey(resolver) orelse return false;
    const source = switch (purpose) {
        .shortening_pending => |source| source,
        .shortening_complete => |source| source,
        .application_answer, .local_promise_answer, .node_settling, .retired => return false,
    };
    return incarnationIsHeld(self, source);
}

pub fn abandon(self: *Session, nomination: Nomination) void {
    std.debug.assert(self.outbound_resolver_link.removeByKey(nomination.resolver_export));
    if (nomination.owns_metadata) {
        // `nominate` recorded `owns_metadata` beside the `put` that created
        // the row, so the undo cannot miss.
        const removed = self.imported_promises.fetchRemove(nomination.source) orelse unreachable;
        var entry = removed.value;
        session.deinitImportedPromise(self.allocator, &entry);
    }
    self.releaseUnsharedExport(nomination.resolver_export);
}

pub fn sourceForResolver(self: *const Session, resolver: model.ExportPosition) ?CallbackState {
    const purpose = self.outbound_resolver_link.getByKey(resolver) orelse return null;
    return switch (purpose) {
        .shortening_pending => |source| .{ .pending = source },
        .shortening_complete => .complete,
        // `resolver` is a partner-named position, so this probe answers one
        // question: is it a shortening resolver? It returns null for every
        // other purpose, and the deliver route's later probes
        // (`isNodeSettlingResolver`, `retiredResolverState`,
        // `answerForResolverExport`) each answer their own. Only the mint
        // discipline keeps an answer purpose off a resolver key, and that
        // discipline holds across dispatches, so the null return is the
        // safe answer to a mint bug or a probing partner.
        .application_answer, .local_promise_answer, .node_settling, .retired => null,
    };
}

/// Validate a proposed link without mutating the forest. Following self-roots
/// includes pending targets and detects a partner-proposed cycle in bounded
/// time. Every existing non-self link was admitted by this same check.
/// The deliver route classifier reaches here only after
/// `sourceForShorteningResolver` saw this resolver's pending link row in the
/// same dispatch, so the lookup below can assert presence and a shortening
/// purpose rather than refuse a partner-named position.
pub fn validateCompletion(self: *const Session, resolver: model.ExportPosition, target: model.FarRef) session.Error!void {
    const purpose = self.outbound_resolver_link.getByKey(resolver) orelse unreachable;
    const source = switch (purpose) {
        .shortening_pending => |incarnation| incarnation,
        .shortening_complete => return session.Error.UnexpectedMessage,
        .application_answer, .local_promise_answer, .node_settling, .retired => unreachable,
    };
    if (!incarnationIsCurrent(self, source)) return;
    var current = target.import_position;
    var remaining = self.imported_promises.count() + 1;
    while (remaining != 0) : (remaining -= 1) {
        if (current == source.position) return session.Error.UnexpectedMessage;
        const entry = self.imported_promises.get(current) orelse return;
        const next = entry.shortening_target;
        if (next == current) return;
        current = next;
    }
    return session.Error.UnexpectedMessage;
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
    const purpose = self.outbound_resolver_link.getByKey(resolver) orelse unreachable;
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
    self.outbound_resolver_link.replaceValueForKey(resolver, .{ .shortening_complete = source });
}

/// Release source-owned state after its final import retain disappears. A
/// pending callback keeps its row-stamped resolver purpose, not an empty map
/// row. Any later reuse gets a fresh row stamp. A completed callback needs no
/// row, while its resolver-purpose tombstone remains until the partner releases
/// the exported resolver mention.
pub fn releaseSourceAuthority(self: *Session, source: session.PromiseIncarnation) void {
    std.debug.assert(!incarnationIsHeld(self, source));
    const pending_resolver = self.outbound_resolver_link.getByValue(.{ .shortening_pending = source });
    const complete_resolver = self.outbound_resolver_link.getByValue(.{ .shortening_complete = source });

    if (pending_resolver != null) {
        if (currentEntry(self, source)) |entry| {
            if (entry.settling_listener_claimed) return;
            // `currentEntry` above found the row in this dispatch, so its
            // undo cannot miss.
            const removed = self.imported_promises.fetchRemove(source.position) orelse unreachable;
            var removed_entry = removed.value;
            session.deinitImportedPromise(self.allocator, &removed_entry);
        }
        return;
    }

    if (incarnationIsCurrent(self, source) and
        !self.findImportedPromise(source.position).?.settling_listener_claimed)
    {
        if (self.imported_promises.fetchRemove(source.position)) |removed| {
            var entry = removed.value;
            session.deinitImportedPromise(self.allocator, &entry);
        }
    }
    if (complete_resolver) |resolver| {
        if (!self.exports.contains(resolver))
            std.debug.assert(self.outbound_resolver_link.removeByKey(resolver));
    }
}

/// The partner released its shortening resolver mention. A pending listener
/// therefore concluded without a shortening callback. Retain a completed
/// tombstone while the source import remains so a later mention cannot install
/// a second shortening listener for the same promise.
pub fn releaseResolverExport(self: *Session, resolver: model.ExportPosition) void {
    if (self.outbound_resolver_link.getByKey(resolver)) |purpose| {
        switch (purpose) {
            .retired => {
                self.releaseRetiredResolverIfUnmentioned(resolver);
                return;
            },
            else => {},
        }
    }
    if (!self.exports.contains(resolver) or self.exports.wireHeld(resolver) != 0) return;
    const purpose = self.outbound_resolver_link.getByKey(resolver) orelse return;
    const source = switch (purpose) {
        .shortening_pending => |incarnation| blk: {
            self.outbound_resolver_link.replaceValueForKey(resolver, .{ .shortening_complete = incarnation });
            break :blk incarnation;
        },
        .shortening_complete => |incarnation| incarnation,
        .application_answer, .local_promise_answer, .node_settling, .retired => return,
    };

    self.releaseUnsharedExport(resolver);
    if (!incarnationIsHeld(self, source)) {
        std.debug.assert(self.outbound_resolver_link.removeByKey(resolver));
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
    return .{ .position = position, .row_id = entry.cell.row_id };
}

fn currentEntry(self: *Session, source: session.PromiseIncarnation) ?*session.ImportedPromise {
    const entry = self.findImportedPromise(source.position) orelse return null;
    return if (entry.cell.row_id == source.row_id) entry else null;
}

fn incarnationIsCurrent(self: *const Session, source: session.PromiseIncarnation) bool {
    const entry = self.imported_promises.get(source.position) orelse return false;
    return entry.cell.row_id == source.row_id;
}

fn incarnationIsHeld(self: *const Session, source: session.PromiseIncarnation) bool {
    return incarnationIsCurrent(self, source) and self.imports.contains(source.position);
}

const ReleaseState = struct {
    total: u64 = 0,
    processed: bool = false,
};

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
    try session.validateGcExport(gc_export.*);

    var states: std.AutoHashMapUnmanaged(model.ImportPosition, ReleaseState) = .empty;
    defer states.deinit(allocator);
    var queue: std.ArrayListUnmanaged(model.ImportPosition) = .empty;
    defer queue.deinit(allocator);
    var extra: std.ArrayListUnmanaged(model.ImportPosition) = .empty;
    defer extra.deinit(allocator);

    for (gc_export.positions, gc_export.deltas) |raw_position, delta| {
        if (raw_position == session.BOOTSTRAP_POSITION) return session.Error.GcUnderflow;
        const position = model.ImportPosition.from(raw_position);
        const gop = try states.getOrPut(allocator, position);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.total = std.math.add(u64, gop.value_ptr.total, delta) catch
            return session.Error.GcUnderflow;
    }

    var state_it = states.iterator();
    while (state_it.next()) |entry| {
        if (entry.value_ptr.total > self.imports.releasable(entry.key_ptr.*)) return session.Error.GcUnderflow;
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
            return session.Error.GcUnderflow;
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

/// Rewrite the far promises the inventory lists, with `root` resolving its
/// by-value root.
fn rewriteSlots(self: *Session, inventory: session.Inventory, root: ?*model.Argument) void {
    for (inventory.slots) |slot| {
        const argument = slot.at(root);
        if (argument.* == .reference) argument.* = .{ .reference = rewriteReference(self, argument.reference) };
    }
}

pub fn rewriteResolution(self: *Session, resolution: *model.Resolution, inventory: session.Inventory) void {
    const root: ?*model.Argument = if (resolution.* == .fulfill) &resolution.fulfill else null;
    rewriteSlots(self, inventory, root);
}

/// Rewrite every far promise in one owned outbound message through the
/// authoritative shortening forest. POD references change in place. No heap is
/// allocated or copied.
pub fn rewriteMessage(self: *Session, message: *model.Message, inventory: session.Inventory) void {
    switch (message.*) {
        .deliver => |*deliver| {
            deliver.target = rewriteReference(self, deliver.target);
            if (deliver.resolve_me_desc) |reference| deliver.resolve_me_desc = rewriteReference(self, reference);
            rewriteSlots(self, inventory, null);
        },
        .resolve => |*resolve| rewriteResolution(self, &resolve.resolution, inventory),
        .listen => |*listen| {
            listen.target = rewriteReference(self, listen.target);
            listen.listener = rewriteReference(self, listen.listener);
        },
        .get => |*get| get.receiver = rewriteReference(self, get.receiver),
        .index => |*index| index.receiver = rewriteReference(self, index.receiver),
        .untag => |*untag| untag.receiver = rewriteReference(self, untag.receiver),
        .gc_export, .gc_answer, .start_session, .abort => {},
    }
}
