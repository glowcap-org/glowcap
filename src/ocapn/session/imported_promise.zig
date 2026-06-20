//! The session's third-party handoff-imported-promise substrate (ADR-0009), as
//! `*Session` helpers plus the one owned-row destructor.
//!
//! A `desc:import-promise` handed to us by an introducing partner names a
//! promise hosted on a *third* peer. Its resolution reaches us as a relayed
//! resolution (forwarded by the introducing session), not a direct
//! `op:resolve`. `op:listen` on such an import installs a listener here; the
//! relay fires it. These mirror the answer-side pipelining substrate in
//! `mod.zig`, keyed on import id instead of answer id. The row type
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
pub fn installThirdPartyImport(self: *Session, import_position: model.ImportId, host: []const u8) !void {
    if (findImportedPromise(self, import_position)) |existing| {
        if (!std.mem.eql(u8, existing.host, host)) return Error.HostMismatch;
        return;
    }
    const host_copy = try self.allocator.dupe(u8, host);
    errdefer self.allocator.free(host_copy);
    try self.registerImport(import_position);
    try self.imported_promises.put(self.allocator, import_position, .{ .host = host_copy });
}

/// Whether `import_position` is a promise imported from a third party (ADR-0009),
/// the gate that admits an `op:listen` on this import as a relayed-resolution
/// listener rather than rejecting it.
pub fn isThirdPartyImport(self: *Session, import_position: model.ImportId) bool {
    return findImportedPromise(self, import_position) != null;
}

/// Register `listener` (taking ownership of its `listener` cap) as wanting the
/// relayed resolution of third-party import `import_position`. On failure the
/// cap is freed. The import must be third-party-hosted.
pub fn installImportedPromiseListener(self: *Session, import_position: model.ImportId, listener: ListenerEntry) !void {
    errdefer model.freeReference(self.allocator, listener.listener);
    const entry = findImportedPromise(self, import_position) orelse return Error.InvalidReference;
    if (entry.listeners.len() >= self.limits.max_listeners_per_target) {
        return Error.ListenerCapExceeded;
    }
    try entry.listeners.append(self.allocator, listener);
}

/// Store the relayed `resolution` for third-party import `import_position` (taking
/// ownership), so a late `op:listen` fires immediately. Replaces any prior
/// stored resolution. On an unknown import the resolution is freed.
pub fn recordRelayedResolution(self: *Session, import_position: model.ImportId, resolution: model.Resolution) !void {
    const entry = findImportedPromise(self, import_position) orelse {
        model.freeResolution(self.allocator, resolution);
        return Error.InvalidReference;
    };
    if (entry.resolution) |prior| model.freeResolution(self.allocator, prior);
    entry.resolution = resolution;
}

/// Hand the caller the listeners registered on third-party import
/// `import_position`, transferring ownership of every entry's listener cap and
/// leaving the import's listener list empty. Returns an empty slice for an
/// unknown import or no listeners. The caller owns the returned slice (release
/// each entry's listener cap, then free the slice with `allocator`).
pub fn takeImportedPromiseListeners(self: *Session, import_position: model.ImportId) ![]ListenerEntry {
    const entry = findImportedPromise(self, import_position) orelse return &.{};
    return entry.listeners.take(self.allocator);
}

/// Borrow the stored relayed resolution for third-party import `import_position`,
/// if one was forwarded. The borrow is valid until the row is mutated or
/// removed.
pub fn importedPromiseResolution(self: *Session, import_position: model.ImportId) ?*const model.Resolution {
    const entry = findImportedPromise(self, import_position) orelse return null;
    if (entry.resolution) |*resolution| return resolution;
    return null;
}

pub fn findImportedPromise(self: *Session, import_position: model.ImportId) ?*ImportedPromise {
    return self.imported_promises.getPtr(import_position);
}

/// Release the owned memory an `ImportedPromise` holds: the host designator,
/// listener caps, and any stored relayed resolution. The listener list is
/// emptied so the struct is safe to drop or remove afterward.
pub fn deinitImportedPromise(allocator: std.mem.Allocator, entry: *ImportedPromise) void {
    allocator.free(entry.host);
    entry.listeners.deinit(allocator);
    if (entry.resolution) |resolution| model.freeResolution(allocator, resolution);
    entry.resolution = null;
}
