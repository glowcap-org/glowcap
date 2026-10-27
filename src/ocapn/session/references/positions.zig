//! Import/export namespace and capability-identity operations for one Session.
//!
//! `Session` retains the authoritative tables. This module owns every
//! operation that admits, allocates, inspects, or unwinds a position in those
//! tables, plus the Node and Host identities attached to an import
//! incarnation. Keeping those doors together prevents the marshal,
//! engine, and Host paths from acquiring different ideas of which capability
//! names the session holds.
//!
//! These operations mutate the existing Session in place. The extraction adds
//! no allocation, copy, lookup, or traversal beyond the table operation each
//! method already performed.

const std = @import("std");
const model = @import("model");

const session = @import("../mod.zig");
const slot = @import("../slot.zig");

const bootstrap_position = session.bootstrap_position;
const Error = session.Error;
const Session = session.Session;

/// Prove a first-marshaled export position belongs to this session. Send
/// validation calls this before apply, and every explicit grant or
/// reservation calls it at the commit boundary.
///
/// An export position is a name in *this* session's namespace and nowhere
/// else, so one from outside the session's range names nothing here: minting
/// a row for it would answer a partner with an object this session does not
/// host. The bootstrap position sits below every range by construction and
/// is always this session's own.
pub fn validateExportPositionForMarshal(self: *const Session, id: model.ExportPosition) Error!void {
    if (id.int() == bootstrap_position or self.exports.contains(id)) return;
    if (!self.exports.inRange(id)) return error.InvalidReference;
}

pub fn registerExport(self: *Session, id: model.ExportPosition) !void {
    try validateExportPositionForMarshal(self, id);
    try self.exports.register(self.allocator, id);
    if (id.int() != bootstrap_position and self.exports.wireHeld(id) == 0) {
        self.exports.retain(id);
    }
}

/// Reserve `id` as an export at its local baseline only: the object can
/// marshal (send-side validation needs a live row), but the partner cannot
/// address the position until the capability's reference first crosses the
/// wire, or `registerExport` grants it explicitly. The positional twin of
/// `allocateExport`. Idempotent, and it never downgrades: reserving an already
/// granted position leaves the grant standing.
pub fn reserveExport(self: *Session, id: model.ExportPosition) !void {
    try validateExportPositionForMarshal(self, id);
    try self.exports.register(self.allocator, id);
}

/// Retain a partner-driven import as the caller's: one the application will
/// release through `recordSend`. A new id is bounded by
/// `SessionLimits.max_imports`. An already-held id increments its wire-delta
/// count so the later `op:gc-exports` releases the same total delta.
pub fn registerImport(self: *Session, id: model.ImportPosition) !void {
    if (id.int() == bootstrap_position) return;
    try self.imports.retain(self.allocator, id, self.limits.max_imports);
}

/// Retain a partner-driven import as the session's own: a mention the
/// session consumed and will release beside the fire or callback that spends
/// it, which no caller's `op:gc-exports` may address. `registerImport` and
/// `adoptImportRetain` in one step.
pub fn retainImportForSession(self: *Session, id: model.ImportPosition) !void {
    if (id.int() == bootstrap_position) return;
    try self.imports.retain(self.allocator, id, self.limits.max_imports);
    self.imports.adoptForSession(id);
}

/// Take one already counted retain on `id` as the session's own. The seams
/// that adopt retained the mention in the same turn (a V1.0 deliver's
/// resolver, a shortening callback's advanced-to promise), so the row is live
/// with a retain left to adopt. The partner bootstrap carries no retain.
pub fn adoptImportRetain(self: *Session, id: model.ImportPosition) void {
    if (id.int() == bootstrap_position) return;
    self.imports.adoptForSession(id);
}

/// Whether a listener nominating `listener` carries the retain a listener
/// entry owns: one the session holds on that import, or none at all for the
/// partner bootstrap, which is permanently addressable. The listener install
/// verbs assert this so an entry built without `retainImportForSession` fails
/// where it is installed rather than where it fires.
pub fn listenerRetainHeld(self: *const Session, listener: model.FarRef) bool {
    if (listener.import_position.int() == bootstrap_position) return true;
    return self.imports.sessionHeld(listener.import_position) != 0;
}

/// Whether releasing one owned reference to `id` requires an outbound
/// `op:gc-exports` delta. The partner bootstrap is permanently addressable and
/// never enters the import table. Every other owned import has a wire retain.
/// The row's presence is an invariant here, not a runtime question: a caller's
/// release is validated against `importReleasable`, so it can never spend the
/// retain the session kept for this release.
pub fn importRequiresWireRelease(self: *const Session, id: model.ImportPosition) bool {
    if (id.int() == bootstrap_position) return false;
    std.debug.assert(self.imports.contains(id));
    return true;
}

pub fn hasExport(self: *const Session, id: model.ExportPosition) bool {
    return self.exports.contains(id);
}

pub fn hasImport(self: *const Session, id: model.ImportPosition) bool {
    return self.imports.contains(id);
}

/// Whether this session can name `id` as a far reference: a row it holds, or
/// the partner's pinned bootstrap, which is always addressable and carries no
/// row. Send validation and Host lifting share this definition.
pub fn holdsImport(self: *const Session, id: model.ImportPosition) bool {
    return id.int() == bootstrap_position or self.imports.contains(id);
}

/// Live export row's CapTP slot, or null if absent.
pub fn exportSlot(self: *const Session, id: model.ExportPosition) ?slot.Slot {
    return self.exports.slotOf(id);
}

/// The reference naming a live export, or null for a position with no live
/// row or a broken one.
pub fn exportReference(self: *const Session, id: model.ExportPosition) ?model.Reference {
    return slot.toReference(self.exportSlot(id) orelse return null);
}

pub fn exportRefcount(self: *const Session, id: model.ExportPosition) u64 {
    return self.exports.count(id);
}

/// Every wire retain on `id`, the session's own included.
pub fn importRefcount(self: *const Session, id: model.ImportPosition) u64 {
    return self.imports.count(id);
}

/// The retains on `id` a caller may release: `importRefcount` less the ones
/// the session keeps for a release of its own. The bound on what the Host
/// may lift as application handles, and what an outbound `op:gc-exports` may
/// name.
pub fn importReleasable(self: *const Session, id: model.ImportPosition) u64 {
    return self.imports.releasable(id);
}

/// Allocate a fresh object export at its local baseline. The row can marshal,
/// but the partner does not hold it until its first wire mention.
pub fn allocateExport(self: *Session) !model.ExportPosition {
    return allocateExportMentioned(self, .object, 0);
}

/// Allocate the promise twin of `allocateExport`, authoritative as unresolved
/// before any codec renders the reference.
pub fn allocatePromiseExport(self: *Session) !model.ExportPosition {
    return allocateExportMentioned(self, .promise, 0);
}

/// Allocate a fresh export of `kind` holding `mentions` wire retains beyond
/// its baseline, in one row install (`ExportTable.allocate`). A mint whose
/// mention rides outside `recordSend` takes the mention's retain here.
pub fn allocateExportMentioned(self: *Session, kind: model.RefKind, mentions: u64) !model.ExportPosition {
    return self.exports.allocate(self.allocator, kind, mentions);
}

/// Roll back one freshly allocated, unshared export. The slot returns to the
/// slab's free list. The retain is certain because
/// every caller runs this as the errdefer of an allocation made in the same
/// dispatch (for example `port.zig`'s dial-mint errdefer), so the decrement
/// cannot underflow.
pub fn releaseUnsharedExport(self: *Session, id: model.ExportPosition) void {
    self.exports.decrement(id, 1) catch unreachable;
}

/// Roll back one `registerImport` retain that never became observable.
/// The retain is certain because `registerImport` (and every other caller)
/// runs this as the errdefer of the retain it took in the same dispatch, so
/// the decrement cannot underflow.
pub fn releaseImportRetain(self: *Session, id: model.ImportPosition) void {
    if (id.int() == bootstrap_position) return;
    self.imports.rollbackRetain(id);
}

/// Release one of the session's own retains on `id` without a wire message:
/// a listener discarded before it fired, a queued fire torn down with its
/// peer, or an install rolled back. A retain that reaches the wire leaves
/// through `recordSessionImportRelease` instead.
pub fn releaseSessionImportRetain(self: *Session, id: model.ImportPosition) void {
    if (id.int() == bootstrap_position) return;
    self.imports.releaseSessionHeld(id, 1);
}

/// The node-unique route under which this import incarnation was enrolled.
pub fn foreignRouteIdFor(self: *const Session, position: model.ImportPosition) ?model.CapabilityRouteId {
    return self.imports.routeIdOf(position);
}

pub fn noteForeignRouteId(self: *Session, position: model.ImportPosition, route_id: model.CapabilityRouteId) !void {
    if (!self.holdsImport(position)) return error.InvalidReference;
    return self.imports.noteRouteId(self.allocator, position, route_id);
}

/// Undo a fresh Node route id without disturbing orthogonal Host identity.
pub fn abandonForeignRouteId(self: *Session, position: model.ImportPosition, route_id: model.CapabilityRouteId) void {
    self.imports.abandonRouteId(position, route_id);
}

pub fn hostCapabilityFor(self: *const Session, position: model.ImportPosition) ?u64 {
    return self.imports.hostRefOf(position);
}

pub fn hostImportIdentity(self: *const Session, position: model.ImportPosition) ?Session.HostImportIdentity {
    return self.imports.hostIdentityOf(position);
}

/// Attach one Host capability id to held import authority. Ordinary imports
/// claim one wire retain. Bootstrap is permanently held and claims none.
/// Session retains only scalar identity, Host owns its meaning and lifetime.
pub fn noteHostCapability(self: *Session, position: model.ImportPosition, ref: u64) !void {
    if (!self.holdsImport(position)) return error.InvalidReference;
    return self.imports.noteHostRef(
        self.allocator,
        position,
        ref,
        @intFromBool(position.int() != bootstrap_position),
    );
}

pub fn claimHostCapabilityRetain(self: *Session, position: model.ImportPosition, ref: u64) !void {
    return self.imports.claimHostRetain(position, ref);
}

pub fn releaseHostCapabilityRetains(self: *Session, position: model.ImportPosition, ref: u64, delta: u64) void {
    self.imports.releaseHostRetains(position, ref, delta);
}

/// Forget Host identity without disturbing the Node route on the same row.
pub fn forgetHostCapability(self: *Session, position: model.ImportPosition, ref: u64) void {
    self.imports.forgetHostRef(position, ref);
}
