//! The session's third-party handoff-imported-promise substrate (ADR-0009), as
//! `*Session` helpers plus the one owned-row destructor.
//!
//! A `desc:import-promise` handed to us by an introducing partner names a
//! promise hosted on a *third* peer. Its resolution reaches us as a relayed
//! resolution (forwarded by the introducing session), not a direct
//! `op:resolve`. `op:listen` on such an import installs a listener here; the
//! relay fires it. These mirror the answer-side pipelining substrate in
//! `mod.zig`, keyed on import position instead of answer position. The row type
//! (`ImportedPromise`) and its storage (`imported_promises`) live on `Session`;
//! these functions are aliased back into the `Session` namespace there, so a
//! caller still writes `sess.installThirdPartyImport(...)`.

const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;
const Error = session.Error;
const ImportedPromise = session.ImportedPromise;
const ListenerEntry = session.ListenerEntry;

/// Root `import_position` at a third-party `host`, registering the import (so it
/// validates as a reference) and marking it handoff-imported. Idempotent for
/// the same host; a re-root with a different host is `Error.HostMismatch`.
/// `host` is duped into session-owned storage.
pub fn installThirdPartyImport(self: *Session, import_position: model.ImportPosition, host: []const u8) !void {
    if (findImportedPromise(self, import_position)) |existing| {
        if (!std.mem.eql(u8, existing.host, host)) return Error.HostMismatch;
        return;
    }
    const host_copy = try self.allocator.dupe(u8, host);
    errdefer self.allocator.free(host_copy);
    try self.registerImport(import_position);
    try self.imported_promises.put(self.allocator, import_position, .{
        .host = host_copy,
        .row_id = self.nextStoreStamp(),
    });
}

/// Whether `import_position` is a promise imported from a third party (ADR-0009),
/// the gate that admits an `op:listen` on this import as a relayed-resolution
/// listener rather than rejecting it.
pub fn isThirdPartyImport(self: *Session, import_position: model.ImportPosition) bool {
    return findImportedPromise(self, import_position) != null;
}

/// Register `listener` (a POD entry) as wanting the relayed resolution of
/// third-party import `import_position`. The import must be
/// third-party-hosted.
pub fn installImportedPromiseListener(self: *Session, import_position: model.ImportPosition, listener: ListenerEntry) !void {
    const entry = findImportedPromise(self, import_position) orelse return Error.InvalidReference;
    if (entry.listeners.len() >= self.limits.max_listeners_per_target) {
        return Error.ListenerCapExceeded;
    }
    try entry.listeners.append(self.allocator, listener);
}

/// Store the relayed `resolution` for third-party import `import_position` (taking
/// ownership), so a late `op:listen` fires immediately. A promise resolves
/// exactly once: a second relay for an already-settled import is refused with
/// `Error.UnexpectedMessage`, mirroring the answer-side resolve-once rule
/// (`validate.validateInboundResolve`) — accepting it would hand two listeners
/// two different final values. On any refusal (unknown import or already
/// settled) the resolution is freed; this function owns it on every outcome.
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
    if (entry.row_id != row_id) {
        model.freeResolution(self.allocator, resolution);
        return false;
    }
    if (entry.resolution != null) {
        model.freeResolution(self.allocator, resolution);
        return Error.UnexpectedMessage;
    }
    entry.resolution = resolution;
    return true;
}

/// Hand the caller the listeners registered on third-party import
/// `import_position`, leaving the import's listener list empty. Returns an
/// empty slice for an unknown import or no listeners. The caller owns the
/// returned slice and frees it with `allocator`; the entries are POD.
pub fn takeImportedPromiseListeners(self: *Session, import_position: model.ImportPosition) ![]ListenerEntry {
    const entry = findImportedPromise(self, import_position) orelse return &.{};
    return entry.listeners.take(self.allocator);
}

/// Borrow the stored relayed resolution for third-party import `import_position`,
/// if one was forwarded. The borrow is valid until the row is mutated or
/// removed.
pub fn importedPromiseResolution(self: *Session, import_position: model.ImportPosition) ?*const model.Resolution {
    const entry = findImportedPromise(self, import_position) orelse return null;
    if (entry.resolution) |*resolution| return resolution;
    return null;
}

pub fn findImportedPromise(self: *Session, import_position: model.ImportPosition) ?*ImportedPromise {
    return self.imported_promises.getPtr(import_position);
}

/// The identity stamp of the live third-party imported-promise row at
/// `import_position`, or null when absent — the imported-promise twin of
/// `inboundAnswerRowId`, captured when a relayed resolution is queued and
/// re-checked at drain so a released-and-re-registered position can never
/// satisfy a stale relay.
pub fn importedPromiseRowId(self: *Session, import_position: model.ImportPosition) ?u64 {
    const entry = findImportedPromise(self, import_position) orelse return null;
    return entry.row_id;
}

/// Release the owned memory an `ImportedPromise` holds: the host designator,
/// the listener list's backing (entries are POD), and any stored relayed
/// resolution. The struct is safe to drop or remove afterward.
pub fn deinitImportedPromise(allocator: std.mem.Allocator, entry: *ImportedPromise) void {
    allocator.free(entry.host);
    entry.listeners.deinit(allocator);
    if (entry.resolution) |resolution| model.freeResolution(allocator, resolution);
    entry.resolution = null;
}
