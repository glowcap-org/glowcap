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
//! on two wires and lose that; nothing here can build one.

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
        .application_answer, .local_promise_answer, .node_settling, .retired => null,
    };
}

/// Validate a proposed link without mutating the forest. Following self-roots
/// includes pending targets and detects a partner-proposed cycle in bounded
/// time; every existing non-self link was admitted by this same check.
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
pub fn complete(self: *Session, resolver: model.ExportPosition, target: model.FarRef) void {
    const purpose = self.outbound_resolver_link.getByKey(resolver) orelse unreachable;
    const source = switch (purpose) {
        .shortening_pending => |incarnation| incarnation,
        else => unreachable,
    };
    if (incarnationIsCurrent(self, source))
        self.findImportedPromise(source.position).?.shortening_target = target.import_position;
    self.outbound_resolver_link.replaceValueForKey(resolver, .{ .shortening_complete = source });
}

/// Release source-owned state after its final import retain disappears. A
/// pending callback keeps its row-stamped resolver purpose, not an empty map
/// row; any later reuse gets a fresh row stamp. A completed callback needs no
/// row, while its resolver-purpose tombstone remains until the partner releases
/// the exported resolver mention.
pub fn releaseSourceAuthority(self: *Session, source: session.PromiseIncarnation) void {
    std.debug.assert(!incarnationIsHeld(self, source));
    const pending_resolver = self.outbound_resolver_link.getByValue(.{ .shortening_pending = source });
    const complete_resolver = self.outbound_resolver_link.getByValue(.{ .shortening_complete = source });

    if (pending_resolver != null) {
        if (currentEntry(self, source)) |entry| {
            if (entry.settling_listener_claimed) return;
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
/// therefore concluded without a shortening callback; retain a completed
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

/// Extend one owned outbound GC operation with the private import retains held
/// by completed shortening edges whose sources this operation releases. The
/// closure matters for chains: releasing 5 may release the edge-owned retain
/// of 6, which can in turn release the edge-owned retain of 7.
///
/// This runs before `recordSend`, so all fallible scratch and replacement
/// storage is acquired before any import count or shortening metadata changes.
/// The expanded positions remain one operation and ordinary GC validation
/// proves the complete decrement before apply commits it.
pub fn expandGcExportReleases(
    self: *Session,
    allocator: std.mem.Allocator,
    gc_export: *model.GcExport,
) !void {
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
        const held = self.imports.count(entry.key_ptr.*);
        if (entry.value_ptr.total > held) return session.Error.GcUnderflow;
        if (entry.value_ptr.total == held and shorteningTarget(self, entry.key_ptr.*) != null)
            try queue.append(allocator, entry.key_ptr.*);
    }

    while (queue.pop()) |source| {
        const source_state = states.getPtr(source) orelse unreachable;
        if (source_state.processed) continue;
        source_state.processed = true;
        const target = shorteningTarget(self, source) orelse continue;
        try extra.append(allocator, target);

        const gop = try states.getOrPut(allocator, target);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.total = std.math.add(u64, gop.value_ptr.total, 1) catch
            return session.Error.GcUnderflow;
        const held = self.imports.count(target);
        if (gop.value_ptr.total > held) return session.Error.GcUnderflow;
        if (gop.value_ptr.total == held and shorteningTarget(self, target) != null)
            try queue.append(allocator, target);
    }

    if (extra.items.len == 0) return;

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
}

fn shorteningTarget(self: *const Session, source: model.ImportPosition) ?model.ImportPosition {
    const entry = self.imported_promises.get(source) orelse return null;
    return if (entry.shortening_target == source) null else entry.shortening_target;
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

fn rewriteArguments(self: *Session, args: []const model.Argument) void {
    for (@constCast(args)) |*arg| rewriteArgument(self, arg);
}

fn rewriteArgument(self: *Session, arg: *model.Argument) void {
    switch (arg.*) {
        .reference => |reference| arg.* = .{ .reference = rewriteReference(self, reference) },
        .list, .set => |items| rewriteArguments(self, items),
        .tagged => |tagged| rewriteArguments(self, tagged.value),
        .@"struct" => |entries| for (@constCast(entries)) |*entry| rewriteArgument(self, &entry.value),
        else => {},
    }
}

pub fn rewriteResolution(self: *Session, resolution: *model.Resolution) void {
    if (resolution.* == .fulfill) rewriteArgument(self, &resolution.fulfill);
}

/// Rewrite every far promise in one owned outbound message through the
/// authoritative shortening forest. POD references change in place; no heap is
/// allocated or copied.
pub fn rewriteMessage(self: *Session, message: *model.Message) void {
    switch (message.*) {
        .deliver => |*deliver| {
            deliver.target = rewriteReference(self, deliver.target);
            if (deliver.resolve_me_desc) |reference| deliver.resolve_me_desc = rewriteReference(self, reference);
            rewriteArguments(self, deliver.args);
        },
        .resolve => |*resolve| rewriteResolution(self, &resolve.resolution),
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
