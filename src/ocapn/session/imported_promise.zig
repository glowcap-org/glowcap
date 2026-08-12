//! Session metadata for imported promises, shared by third-party handoff relay
//! and next-profile shortening and settling subscriptions.
//!
//! A `desc:import-promise` handed to us by an introducing partner names a
//! promise hosted on a *third* peer. Its resolution reaches us as a relayed
//! resolution (forwarded by the introducing session), not a direct settlement
//! callback. `op:listen` on the corresponding proxy export installs a
//! listener here; the relay fires it. These mirror the answer-side pipelining
//! substrate in `mod.zig`, keyed on import position instead of answer position.
//! The row type (`ImportedPromise`) and its storage (`imported_promises`) live
//! on `Session`; these helpers are aliased back into that namespace.

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");
const cell_ops = @import("promise_listen_cell.zig");

const Session = session.Session;
const Error = session.Error;
const ImportedPromise = session.ImportedPromise;
const ListenerEntry = session.ListenerEntry;

/// Root `import_position` at a third-party `host`, registering the import (so it
/// validates as a reference) and marking it handoff-imported. Idempotent for
/// the same host; a re-root with a different host is `Error.HostMismatch`.
/// `host` is interned in `key_arena` (session-lifetime; shared across rows that
/// name the same introducing host — never N gpa dupes of one designator).
pub fn installThirdPartyImport(self: *Session, import_position: model.ImportPosition, host: []const u8) !void {
    if (findImportedPromise(self, import_position)) |existing| {
        if (existing.host) |known| {
            if (!std.mem.eql(u8, known, host)) return Error.HostMismatch;
            return;
        }
        existing.host = try internThirdPartyHost(self, host);
        return;
    }
    // Reserve the owning row before taking wire authority. Once the import
    // retain succeeds, every remaining commit step is infallible; a failed
    // host intern rolls the retain back rather than leaving an import with no
    // third-party routing row.
    try self.imported_promises.ensureUnusedCapacity(self.allocator, 1);
    try self.registerImport(import_position);
    errdefer self.releaseImportRetain(import_position);
    const host_interned = try internThirdPartyHost(self, host);
    self.imported_promises.putAssumeCapacity(import_position, .{
        .host = host_interned,
        .cell = .{ .row_id = self.nextStoreStamp() },
        .shortening_target = import_position,
    });
}

/// Roll back a freshly installed third-party import that never became
/// observable. The row and its single import retain were created together by
/// `installThirdPartyImport`; listeners or a resolution would prove the caller
/// crossed the publication boundary and make this operation invalid.
pub fn abandonUnsharedThirdPartyImport(self: *Session, import_position: model.ImportPosition) void {
    const row = self.imported_promises.getPtr(import_position) orelse unreachable;
    std.debug.assert(row.host != null);
    std.debug.assert(row.cell.listeners.len() == 0 and row.cell.resolution == null);
    cell_ops.deinit(self.allocator, &row.cell);
    std.debug.assert(self.imported_promises.remove(import_position));
    self.releaseImportRetain(import_position);
}

/// One designator buffer per distinct host string for the session's life.
fn internThirdPartyHost(self: *Session, host: []const u8) ![]const u8 {
    var it = self.imported_promises.valueIterator();
    while (it.next()) |entry| {
        const known = entry.host orelse continue;
        if (std.mem.eql(u8, known, host)) return known;
    }
    return try self.key_arena.allocator().dupe(u8, host);
}

/// Whether `import_position` is a promise imported from a third party (ADR-0009),
/// the internal link that routes an `op:listen` on the corresponding proxy
/// export to the relayed-resolution listener store.
pub fn isThirdPartyImport(self: *Session, import_position: model.ImportPosition) bool {
    if (!self.imports.contains(import_position)) return false;
    const entry = findImportedPromise(self, import_position) orelse return false;
    return entry.host != null;
}

/// Register `listener` (a POD entry) as wanting the relayed resolution of
/// third-party import `import_position`. The import must be
/// third-party-hosted.
pub fn installImportedPromiseListener(self: *Session, import_position: model.ImportPosition, listener: ListenerEntry) !void {
    const entry = findImportedPromise(self, import_position) orelse return Error.InvalidReference;
    try cell_ops.installListener(&entry.cell, self.allocator, self.limits.max_listeners_per_target, listener);
}

/// Record a relayed resolution against the third-party import row, returning
/// whether it was stored (`false` = moot, dropped). `row_id` is the row
/// identity the relay was queued against: a mismatch means that row was torn
/// down (GC co-eviction) and a *different* third-party promise re-registered at
/// this position, so the stale relay is moot and fires nothing — the same
/// row-identity guard `resolveStoreChecked` gives the `settled_answer` and
/// `listener_fire` carriers over this store (a queued carrier reading a store by
/// position must prove the row is the instance it was accounted against).
pub fn recordRelayedResolution(self: *Session, import_position: model.ImportPosition, row_id: u64, resolution: model.Resolution) !bool {
    const entry = findImportedPromise(self, import_position) orelse {
        model.freeResolution(self.allocator, resolution);
        return Error.InvalidReference;
    };
    if (entry.cell.row_id != row_id) {
        model.freeResolution(self.allocator, resolution);
        return false;
    }
    if (entry.cell.resolution != null) {
        model.freeResolution(self.allocator, resolution);
        return Error.UnexpectedMessage;
    }
    entry.cell.resolution = resolution;
    return true;
}

/// Hand the caller the listeners registered on third-party import
/// `import_position`, leaving the import's listener list empty. Returns an
/// empty slice for an unknown import or no listeners. The caller owns the
/// returned slice and frees it with `allocator`; the entries are POD.
pub fn takeImportedPromiseListeners(self: *Session, import_position: model.ImportPosition) ![]ListenerEntry {
    const entry = findImportedPromise(self, import_position) orelse return &.{};
    return cell_ops.takeListeners(&entry.cell, self.allocator);
}

/// Roll back a preparation-time listener take. The row is externally
/// synchronized and the preparation has not committed its resolution, so the
/// list is still empty and can retake the owned allocation directly.
pub fn restoreImportedPromiseListeners(self: *Session, import_position: model.ImportPosition, listeners: []ListenerEntry) void {
    const entry = findImportedPromise(self, import_position) orelse unreachable;
    cell_ops.restoreListeners(&entry.cell, listeners);
}

/// Borrow the stored relayed resolution for third-party import `import_position`,
/// if one was forwarded. The borrow is valid until the row is mutated or
/// removed.
pub fn importedPromiseResolution(self: *Session, import_position: model.ImportPosition) ?*const model.Resolution {
    const entry = findImportedPromise(self, import_position) orelse return null;
    return cell_ops.resolution(&entry.cell);
}

/// Find one stored relayed resolution whose previously installed listeners
/// still need carriers. This state exists only when terminal settlement had to
/// commit under allocator or outbound pressure; ordinary settlement detaches
/// and reserves every listener before recording the store.
pub fn pendingImportedPromiseFire(self: *Session) ?model.ImportPosition {
    var it = self.imported_promises.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.cell.resolution != null and entry.value_ptr.cell.listeners.len() != 0)
            return entry.key_ptr.*;
    }
    return null;
}

pub fn findImportedPromise(self: *Session, import_position: model.ImportPosition) ?*ImportedPromise {
    return self.imported_promises.getPtr(import_position);
}

/// Prepared local-consumer move for a shortening callback. A target with no
/// subscription takes the source's row directly. A subscribed target keeps
/// its wire listener and receives this preallocated merged follower list.
pub const SettlingMovePlan = struct {
    source: session.PromiseIncarnation,
    target: model.ImportPosition,
    converges: bool,
    primary: ?model.AnswerPosition = null,
    followers: std.ArrayListUnmanaged(model.AnswerPosition) = .empty,

    pub fn deinit(self: *SettlingMovePlan, allocator: std.mem.Allocator) void {
        self.followers.deinit(allocator);
        self.* = undefined;
    }
};

/// Claim this promise incarnation's one next-profile wire settling
/// subscription for one local application or Node consumer. False means the
/// target already has the wire subscription; convergence joins consumers
/// through `prepareSettlingMove` instead of sending another listener.
pub fn claimSettlingListener(
    self: *Session,
    import_position: model.ImportPosition,
    listener_export: model.ExportPosition,
    answer: ?model.AnswerPosition,
) !bool {
    const entry = findImportedPromise(self, import_position) orelse return false;
    if (entry.settling_listener_claimed) return false;
    if (answer) |application_answer| {
        const answer_entry = self.outbound_answers.getPtr(application_answer) orelse return false;
        const purpose = self.outbound_resolver_link.getByKey(listener_export) orelse return false;
        switch (purpose) {
            .application_answer => |linked| if (linked != application_answer) return false,
            .node_settling, .retired, .shortening_pending, .shortening_complete => return false,
        }
        answer_entry.settling_target = import_position;
        answer_entry.settling_index = 0;
        answer_entry.has_settling_target = true;
    } else {
        try self.outbound_resolver_link.put(self.allocator, listener_export, .{
            .node_settling = .{
                .resolver_export = listener_export,
                .settling_source = .{
                    .position = import_position,
                    .row_id = entry.cell.row_id,
                },
            },
        });
    }
    entry.settling_listener_claimed = true;
    entry.settling_listener_export = listener_export;
    entry.settling_answer = answer;
    entry.settling_node_claimed = answer == null;
    return true;
}

pub fn abandonSettlingListener(self: *Session, import_position: model.ImportPosition) void {
    const entry = findImportedPromise(self, import_position) orelse return;
    std.debug.assert(entry.settling_listener_claimed);
    if (entry.settling_answer) |answer| clearAnswerSettlingLink(self, answer);
    for (entry.settling_followers.items) |answer| clearAnswerSettlingLink(self, answer);
    entry.settling_followers.clearRetainingCapacity();
    if (entry.settling_node_claimed and entry.settling_answer == null)
        std.debug.assert(self.outbound_resolver_link.removeByKey(entry.settling_listener_export));
    entry.settling_listener_claimed = false;
    entry.settling_listener_export = .from(0);
    entry.settling_answer = null;
    entry.settling_node_claimed = false;
}

pub fn shortenedTarget(self: *Session, source: model.ImportPosition) model.ImportPosition {
    var current = source;
    var remaining = self.imported_promises.count() + 1;
    while (remaining != 0) : (remaining -= 1) {
        const entry = findImportedPromise(self, current) orelse return current;
        if (entry.shortening_target == current) return current;
        current = entry.shortening_target;
    }
    return source;
}

pub fn settlingAnswer(self: *Session, source: session.PromiseIncarnation) ?model.AnswerPosition {
    const entry = findImportedPromise(self, source.position) orelse return null;
    if (entry.cell.row_id != source.row_id) return null;
    return entry.settling_answer;
}

pub fn settlingListenerExport(self: *Session, source: session.PromiseIncarnation) ?model.ExportPosition {
    const entry = findImportedPromise(self, source.position) orelse return null;
    if (entry.cell.row_id != source.row_id or !entry.settling_listener_claimed) return null;
    return entry.settling_listener_export;
}

pub fn settlingNodeClaimed(self: *Session, source: session.PromiseIncarnation) bool {
    const entry = findImportedPromise(self, source.position) orelse return false;
    return entry.cell.row_id == source.row_id and entry.settling_listener_claimed and entry.settling_node_claimed;
}

pub fn settlingConsumerClaimed(self: *Session, source: session.PromiseIncarnation) bool {
    const entry = findImportedPromise(self, source.position) orelse return false;
    return entry.cell.row_id == source.row_id and
        entry.settling_listener_claimed and
        (entry.settling_answer != null or entry.settling_node_claimed);
}

/// Promise shortening discards the old peer's settling-only listener. When its
/// local consumers are already gone, conclude the pending race tombstone
/// instead of rearming it on the shortened target.
pub fn discardUnconsumedSettlingListener(self: *Session, source: session.PromiseIncarnation) void {
    const entry = findImportedPromise(self, source.position) orelse return;
    if (entry.cell.row_id != source.row_id or
        !entry.settling_listener_claimed or
        entry.settling_answer != null or
        entry.settling_node_claimed)
        return;
    std.debug.assert(entry.settling_followers.items.len == 0);
    const resolver = entry.settling_listener_export;
    const purpose = self.outbound_resolver_link.getByKey(resolver) orelse unreachable;
    switch (purpose) {
        .retired => {},
        else => unreachable,
    }
    entry.settling_listener_claimed = false;
    entry.settling_listener_export = .from(0);
    self.outbound_resolver_link.replaceValueForKey(resolver, .{
        .retired = .{
            .resolver_export = resolver,
            .state = .complete,
        },
    });
    self.releaseRetiredResolverIfUnmentioned(resolver);
}

pub fn detachSettlingNodeConsumer(
    self: *Session,
    source: session.PromiseIncarnation,
    resolver_export: model.ExportPosition,
) void {
    const entry = findImportedPromise(self, source.position) orelse return;
    if (entry.cell.row_id != source.row_id or
        !entry.settling_listener_claimed or
        entry.settling_listener_export != resolver_export or
        !entry.settling_node_claimed)
        return;
    if (entry.settling_answer != null) {
        entry.settling_node_claimed = false;
        return;
    }
    self.retireNodeSettlingResolver(resolver_export);
}

/// Borrow the additional application answers sharing `primary`'s settling
/// callback. Empty when `primary` is not the subscription's inline leader.
pub fn settlingFollowersForAnswer(self: *Session, primary: model.AnswerPosition) []const model.AnswerPosition {
    const answer_entry = self.outbound_answers.getPtr(primary) orelse return &.{};
    if (!answer_entry.has_settling_target or answer_entry.settling_index != 0) return &.{};
    const promise = findImportedPromise(self, answer_entry.settling_target) orelse return &.{};
    if (promise.settling_answer != primary) return &.{};
    return promise.settling_followers.items;
}

/// Validate that every local alias is still an unsettled outbound answer. The
/// primary callback performs the wire-value validation once; aliases share
/// that value and need only their own answer-state check.
pub fn validateSettlingFollowers(self: *Session, primary: model.AnswerPosition) !void {
    for (settlingFollowersForAnswer(self, primary)) |answer| {
        const cell = self.outbound_answers.getPtr(answer) orelse return Error.InvalidReference;
        if (cell.status() != .pending) return Error.UnexpectedMessage;
    }
}

/// Apply the primary callback's outcome to every local alias without
/// re-installing its introduced imports. The one wire resolution introduced
/// those references once; local fan-out does not create more wire mentions.
pub fn applySettlingFollowers(
    self: *Session,
    primary: model.AnswerPosition,
    resolution: model.view.Resolution,
) void {
    for (settlingFollowersForAnswer(self, primary)) |answer| {
        const cell = self.outbound_answers.getPtr(answer) orelse unreachable;
        switch (resolution) {
            .fulfill => cell.fulfill() catch unreachable,
            .@"break" => cell.breakCell() catch unreachable,
        }
    }
}

/// Conclude `primary`'s one-shot wire subscription and transfer its follower
/// list to the caller. The caller owns the returned list and must deinit it.
pub fn takeSettlingFollowers(
    self: *Session,
    primary: model.AnswerPosition,
) std.ArrayListUnmanaged(model.AnswerPosition) {
    const answer_entry = self.outbound_answers.getPtr(primary) orelse return .empty;
    if (!answer_entry.has_settling_target or answer_entry.settling_index != 0) return .empty;
    const promise = findImportedPromise(self, answer_entry.settling_target) orelse return .empty;
    if (promise.settling_answer != primary) return .empty;
    const source: session.PromiseIncarnation = .{
        .position = answer_entry.settling_target,
        .row_id = promise.cell.row_id,
    };

    clearAnswerSettlingLink(self, primary);
    for (promise.settling_followers.items) |answer| clearAnswerSettlingLink(self, answer);
    const followers = promise.settling_followers;
    promise.settling_followers = .empty;
    promise.settling_listener_claimed = false;
    promise.settling_listener_export = .from(0);
    promise.settling_answer = null;
    promise.settling_node_claimed = false;
    if (!self.hasImport(source.position)) self.releaseShorteningSourceAuthority(source);
    return followers;
}

/// Detach a released local answer from its settling subscription in O(1).
/// A released follower is swap-removed. Releasing the primary promotes the
/// final follower and retargets the surviving resolver link; when only a Node
/// consumer remains, the application resolver link is removed but the wire
/// listener stays armed for the Node.
pub fn unlinkSettlingAnswer(
    self: *Session,
    answer: model.AnswerPosition,
) ?session.PromiseIncarnation {
    const answer_entry = self.outbound_answers.getPtr(answer) orelse return null;
    if (!answer_entry.has_settling_target) return null;
    const target = answer_entry.settling_target;
    const index = answer_entry.settling_index;
    const promise = findImportedPromise(self, target) orelse {
        clearAnswerSettlingLink(self, answer);
        return null;
    };
    if (!promise.settling_listener_claimed) {
        clearAnswerSettlingLink(self, answer);
        return null;
    }

    if (index != 0) {
        const follower_index = index - 1;
        if (follower_index >= promise.settling_followers.items.len or
            promise.settling_followers.items[follower_index] != answer)
        {
            clearAnswerSettlingLink(self, answer);
            return null;
        }
        const removed = promise.settling_followers.swapRemove(follower_index);
        std.debug.assert(removed == answer);
        if (follower_index < promise.settling_followers.items.len) {
            const moved = promise.settling_followers.items[follower_index];
            setAnswerSettlingLink(self, moved, target, follower_index + 1);
        }
        clearAnswerSettlingLink(self, answer);
        return null;
    }

    if (promise.settling_answer != answer) {
        clearAnswerSettlingLink(self, answer);
        return null;
    }
    if (promise.settling_followers.pop()) |promoted| {
        promise.settling_answer = promoted;
        setAnswerSettlingLink(self, promoted, target, 0);
        self.outbound_resolver_link.replaceValueForKey(
            promise.settling_listener_export,
            .{ .application_answer = promoted },
        );
    } else {
        promise.settling_answer = null;
        if (promise.settling_node_claimed) {
            const listener = promise.settling_listener_export;
            self.outbound_resolver_link.replaceValueForKey(listener, .{
                .node_settling = .{
                    .resolver_export = listener,
                    .settling_source = .{
                        .position = target,
                        .row_id = promise.cell.row_id,
                    },
                },
            });
        }
    }
    clearAnswerSettlingLink(self, answer);
    if (promise.settling_answer == null and !promise.settling_node_claimed) {
        return .{ .position = target, .row_id = promise.cell.row_id };
    }
    return null;
}

pub fn settlingListenerClaimed(self: *Session, source: session.PromiseIncarnation) bool {
    const entry = findImportedPromise(self, source.position) orelse return false;
    return entry.cell.row_id == source.row_id and entry.settling_listener_claimed;
}

pub fn prepareSettlingMove(
    self: *Session,
    source: session.PromiseIncarnation,
    target: model.ImportPosition,
) !SettlingMovePlan {
    const source_entry = findImportedPromise(self, source.position) orelse return Error.InvalidReference;
    if (source_entry.cell.row_id != source.row_id or !source_entry.settling_listener_claimed)
        return Error.InvalidReference;
    const target_entry = findImportedPromise(self, target) orelse return Error.InvalidReference;
    var plan: SettlingMovePlan = .{
        .source = source,
        .target = target,
        .converges = target_entry.settling_listener_claimed,
    };
    errdefer plan.deinit(self.allocator);
    if (!plan.converges) return plan;

    const target_count = @as(usize, @intFromBool(target_entry.settling_answer != null)) + target_entry.settling_followers.items.len;
    const source_count = @as(usize, @intFromBool(source_entry.settling_answer != null)) + source_entry.settling_followers.items.len;
    const total = target_count + source_count;
    if (total == 0) return plan;
    plan.primary = target_entry.settling_answer orelse source_entry.settling_answer.?;
    try plan.followers.ensureTotalCapacityPrecise(self.allocator, total - 1);
    appendAnswersExceptPrimary(&plan.followers, target_entry, plan.primary.?);
    appendAnswersExceptPrimary(&plan.followers, source_entry, plan.primary.?);
    return plan;
}

pub fn commitSettlingMove(
    self: *Session,
    plan: *SettlingMovePlan,
) void {
    const source_entry = findImportedPromise(self, plan.source.position) orelse unreachable;
    std.debug.assert(source_entry.cell.row_id == plan.source.row_id);
    std.debug.assert(source_entry.settling_listener_claimed);
    const target_entry = findImportedPromise(self, plan.target) orelse unreachable;

    if (!plan.converges) {
        std.debug.assert(!target_entry.settling_listener_claimed);
        target_entry.settling_listener_claimed = true;
        target_entry.settling_listener_export = source_entry.settling_listener_export;
        target_entry.settling_answer = source_entry.settling_answer;
        target_entry.settling_followers = source_entry.settling_followers;
        target_entry.settling_node_claimed = source_entry.settling_node_claimed;
        source_entry.settling_followers = .empty;
        relinkSettlingAnswers(self, target_entry, plan.target);
        if (self.outbound_resolver_link.getByKey(target_entry.settling_listener_export)) |purpose| {
            switch (purpose) {
                .node_settling => |node| self.outbound_resolver_link.replaceValueForKey(
                    target_entry.settling_listener_export,
                    .{ .node_settling = .{
                        .resolver_export = node.resolver_export,
                        .settling_source = .{
                            .position = plan.target,
                            .row_id = target_entry.cell.row_id,
                        },
                    } },
                ),
                .retired => |retired| self.outbound_resolver_link.replaceValueForKey(
                    target_entry.settling_listener_export,
                    .{ .retired = .{
                        .resolver_export = retired.resolver_export,
                        .settling_source = .{
                            .position = plan.target,
                            .row_id = target_entry.cell.row_id,
                        },
                        .state = retired.state,
                    } },
                ),
                else => {},
            }
        }
    } else {
        std.debug.assert(target_entry.settling_listener_claimed);
        const source_listener = source_entry.settling_listener_export;
        if (source_entry.settling_answer) |source_answer| {
            self.outbound_resolver_link.replaceValueForKey(source_listener, .{
                .retired = .{
                    .resolver_export = source_listener,
                    .state = .complete,
                },
            });
            if (target_entry.settling_answer == null) {
                self.outbound_resolver_link.replaceValueForKey(
                    target_entry.settling_listener_export,
                    .{ .application_answer = source_answer },
                );
            }
        } else if (self.outbound_resolver_link.getByKey(source_listener)) |purpose| {
            switch (purpose) {
                .node_settling, .retired => self.outbound_resolver_link.replaceValueForKey(
                    source_listener,
                    .{ .retired = .{
                        .resolver_export = source_listener,
                        .state = .complete,
                    } },
                ),
                else => std.debug.assert(self.outbound_resolver_link.removeByKey(source_listener)),
            }
        }
        // Keep the completed tombstone only while the partner still owns the
        // wire mention. The partner may have returned it before the shortening
        // callback reached us, so conclude that ordering here as well.
        self.releaseRetiredResolverIfUnmentioned(source_listener);
        target_entry.settling_followers.deinit(self.allocator);
        source_entry.settling_followers.deinit(self.allocator);
        target_entry.settling_answer = plan.primary;
        target_entry.settling_followers = plan.followers;
        target_entry.settling_node_claimed = target_entry.settling_node_claimed or source_entry.settling_node_claimed;
        plan.followers = .empty;
        source_entry.settling_followers = .empty;
        relinkSettlingAnswers(self, target_entry, plan.target);
    }

    source_entry.settling_listener_claimed = false;
    source_entry.settling_listener_export = .from(0);
    source_entry.settling_answer = null;
    source_entry.settling_node_claimed = false;
}

fn appendAnswersExceptPrimary(
    out: *std.ArrayListUnmanaged(model.AnswerPosition),
    entry: *const ImportedPromise,
    primary: model.AnswerPosition,
) void {
    if (entry.settling_answer) |answer| {
        if (answer != primary) out.appendAssumeCapacity(answer);
    }
    for (entry.settling_followers.items) |answer| {
        if (answer != primary) out.appendAssumeCapacity(answer);
    }
}

fn relinkSettlingAnswers(self: *Session, entry: *const ImportedPromise, target: model.ImportPosition) void {
    if (entry.settling_answer) |answer| setAnswerSettlingLink(self, answer, target, 0);
    for (entry.settling_followers.items, 1..) |answer, index|
        setAnswerSettlingLink(self, answer, target, index);
}

fn setAnswerSettlingLink(
    self: *Session,
    answer: model.AnswerPosition,
    target: model.ImportPosition,
    index: usize,
) void {
    const cell = self.outbound_answers.getPtr(answer) orelse unreachable;
    cell.settling_target = target;
    cell.settling_index = index;
    cell.has_settling_target = true;
}

fn clearAnswerSettlingLink(self: *Session, answer: model.AnswerPosition) void {
    const cell = self.outbound_answers.getPtr(answer) orelse return;
    cell.has_settling_target = false;
    cell.settling_index = 0;
}

/// The identity stamp of the live third-party imported-promise row at
/// `import_position`, or null when absent — the imported-promise twin of
/// `inboundAnswerRowId`, captured when a relayed resolution is queued and
/// re-checked at drain so a released-and-re-registered position can never
/// satisfy a stale relay.
pub fn importedPromiseRowId(self: *Session, import_position: model.ImportPosition) ?u64 {
    const entry = findImportedPromise(self, import_position) orelse return null;
    return entry.cell.row_id;
}

/// Release the listen cell an `ImportedPromise` holds. The host designator
/// lives in `Session.key_arena` (interned) and is freed with the session.
pub fn deinitImportedPromise(allocator: std.mem.Allocator, entry: *ImportedPromise) void {
    entry.settling_followers.deinit(allocator);
    cell_ops.deinit(allocator, &entry.cell);
}
