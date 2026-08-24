//! Session metadata for imported promises, shared by third-party handoff relay
//! and next-profile shortening and settling subscriptions.
//!
//! A `desc:import-promise` handed to us by an introducing partner names a
//! promise hosted on a *third* peer. Its resolution reaches us as a relayed
//! resolution (forwarded by the introducing session), not a direct settlement
//! callback. `op:listen` on the corresponding proxy export installs a
//! listener here; the relay fires it. These mirror the answer-side pipelining
//! substrate in `pipeline.zig`, keyed on import position instead of answer
//! position.
//! The row type (`ImportedPromise`) and its storage (`imported_promises`) live
//! on `Session`; these helpers are aliased back into that namespace.

const std = @import("std");
const model = @import("model");
const session = @import("../mod.zig");
const cell_ops = @import("listen_cell.zig");
const settling = @import("imported/settling.zig");

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
    const promise_target = self.promiseTargetForResolution(resolution) catch |err| {
        model.freeResolution(self.allocator, resolution);
        return err;
    };
    entry.cell.resolution = .{ .value = resolution, .promise_target = promise_target };
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

pub fn importedPromiseStoredResolution(
    self: *Session,
    import_position: model.ImportPosition,
) ?*const session.StoredResolution {
    const entry = findImportedPromise(self, import_position) orelse return null;
    return cell_ops.storedResolution(&entry.cell);
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

pub const SettlingMovePlan = settling.SettlingMovePlan;
pub const claimSettlingListener = settling.claimSettlingListener;
pub const abandonSettlingListener = settling.abandonSettlingListener;
pub const settlingAnswer = settling.settlingAnswer;
pub const settlingListenerExport = settling.settlingListenerExport;
pub const settlingNodeClaimed = settling.settlingNodeClaimed;
pub const settlingConsumerClaimed = settling.settlingConsumerClaimed;
pub const discardUnconsumedSettlingListener = settling.discardUnconsumedSettlingListener;
pub const detachSettlingNodeConsumer = settling.detachSettlingNodeConsumer;
pub const settlingFollowersForAnswer = settling.settlingFollowersForAnswer;
pub const validateSettlingFollowers = settling.validateSettlingFollowers;
pub const applySettlingFollowers = settling.applySettlingFollowers;
pub const takeSettlingFollowers = settling.takeSettlingFollowers;
pub const unlinkSettlingAnswer = settling.unlinkSettlingAnswer;
pub const settlingListenerClaimed = settling.settlingListenerClaimed;
pub const prepareSettlingMove = settling.prepareSettlingMove;
pub const commitSettlingMove = settling.commitSettlingMove;

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
