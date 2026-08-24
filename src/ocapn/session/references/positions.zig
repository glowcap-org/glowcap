//! Import/export namespace and capability-identity operations for one Session.
//!
//! `Session` retains the authoritative tables and allocation cursors. This
//! module owns every operation that admits, allocates, inspects, or unwinds a
//! position in those tables, plus the Node and Host identities attached to an
//! import incarnation. Keeping those doors together prevents the marshal,
//! engine, and Host paths from acquiring different ideas of which capability
//! names the session actually holds.
//!
//! These operations mutate the existing Session in place. The extraction adds
//! no allocation, copy, lookup, or traversal beyond the table operation each
//! method already performed.

const std = @import("std");
const model = @import("model");

const session = @import("../mod.zig");
const slot = @import("../slot.zig");

const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;
const Error = session.Error;
const Session = session.Session;

/// The marshal-side door into `admitExportPosition`, for `apply`'s
/// first-mention branch. Same rule, reachable from the sibling module.
pub fn admitExportPositionForMarshal(self: *Session, id: model.ExportPosition) Error!void {
    return admitExportPosition(self, id);
}

/// Prove a first-marshaled export position belongs to this session without
/// mutating its allocator cursor. Send validation calls this before apply;
/// `admitExportPosition` reuses it at the commit boundary.
pub fn validateExportPositionForMarshal(self: *const Session, id: model.ExportPosition) Error!void {
    if (id.int() == BOOTSTRAP_POSITION or self.exports.contains(id)) return;
    if (id.int() < self.export_base or id.int() >= self.export_position_end)
        return Error.InvalidReference;
}

/// Admit an export position that did not come from this session's own
/// allocator, and advance past it.
///
/// An export position is a name in *this* session's namespace and nowhere
/// else, so one from outside the session's range names nothing here. Minting a
/// row for it would answer a partner with an object this session does not host,
/// and dragging the allocator up to it would spend the range the session has
/// left, after which it can export nothing at all. Every door a position can
/// arrive through — an explicit grant, a reservation, or a first marshal in a
/// sent resolve — comes through here.
///
/// The bootstrap position sits below every range by construction and is always
/// this session's own.
fn admitExportPosition(self: *Session, id: model.ExportPosition) Error!void {
    try validateExportPositionForMarshal(self, id);
    if (id.int() == BOOTSTRAP_POSITION or self.exports.contains(id)) return;
    if (id.int() >= self.next_export_position) {
        self.next_export_position = id.int() + 1;
    }
}

pub fn registerExport(self: *Session, id: model.ExportPosition) !void {
    try admitExportPosition(self, id);
    try self.exports.register(self.allocator, id);
    if (id.int() != BOOTSTRAP_POSITION and self.exports.wireHeld(id) == 0) {
        try self.exports.retain(self.allocator, id);
    }
}

/// Reserve `id` as an export at its local baseline only: the object can
/// marshal (send-side validation needs a live row), but the partner cannot
/// address the position until the capability's reference first crosses the
/// wire — or `registerExport` grants it explicitly. The positional twin of
/// `allocateExport`. Idempotent, and it never downgrades: reserving an already
/// granted position leaves the grant standing.
pub fn reserveExport(self: *Session, id: model.ExportPosition) !void {
    try admitExportPosition(self, id);
    try self.exports.register(self.allocator, id);
}

/// Retain a partner-driven import. A new id is bounded by
/// `SessionLimits.max_imports`; an already-held id increments its wire-delta
/// count so the later `op:gc-exports` releases the same total delta.
pub fn registerImport(self: *Session, id: model.ImportPosition) !void {
    if (id.int() == BOOTSTRAP_POSITION) return;
    try self.imports.retain(self.allocator, id, self.limits.max_imports);
}

/// Whether releasing one owned reference to `id` requires an outbound
/// `op:gc-exports` delta. The partner bootstrap is permanently addressable and
/// never enters the import table; every other owned import has a wire retain.
pub fn importRequiresWireRelease(self: *const Session, id: model.ImportPosition) bool {
    if (id.int() == BOOTSTRAP_POSITION) return false;
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
    return id.int() == BOOTSTRAP_POSITION or self.imports.contains(id);
}

/// Live export row's CapTP slot, or null if absent.
pub fn exportSlot(self: *const Session, id: model.ExportPosition) ?slot.Slot {
    return self.exports.slotOf(id);
}

/// Live import row's CapTP slot, or null if absent.
pub fn importSlot(self: *const Session, id: model.ImportPosition) ?slot.Slot {
    return self.imports.slotOf(id);
}

pub fn exportRefcount(self: *const Session, id: model.ExportPosition) u64 {
    return self.exports.count(id);
}

pub fn importRefcount(self: *const Session, id: model.ImportPosition) u64 {
    return self.imports.count(id);
}

/// Allocate a fresh object export at its local baseline. The row can marshal,
/// but the partner does not hold it until its first wire mention.
pub fn allocateExport(self: *Session) !model.ExportPosition {
    if (self.next_export_position >= self.export_position_end)
        return Error.ExportRangeExhausted;
    const id = model.ExportPosition.from(self.next_export_position);
    try self.exports.register(self.allocator, id);
    self.next_export_position += 1;
    return id;
}

/// Allocate the promise twin of `allocateExport`, authoritative as unresolved
/// before any codec renders the reference.
pub fn allocatePromiseExport(self: *Session) !model.ExportPosition {
    if (self.next_export_position >= self.export_position_end)
        return Error.ExportRangeExhausted;
    const id = model.ExportPosition.from(self.next_export_position);
    try self.exports.registerPromise(self.allocator, id);
    self.next_export_position += 1;
    return id;
}

/// Roll back one freshly allocated, unshared export. Position allocation stays
/// monotonic; the skipped id is not reused.
pub fn releaseUnsharedExport(self: *Session, id: model.ExportPosition) void {
    self.exports.decrement(id, 1) catch unreachable;
}

/// Roll back one `registerImport` retain that never became observable.
pub fn releaseImportRetain(self: *Session, id: model.ImportPosition) void {
    if (id.int() == BOOTSTRAP_POSITION) return;
    self.imports.decrement(id, 1) catch unreachable;
}

/// The node-unique route under which this import incarnation was enrolled.
pub fn foreignRouteIdFor(self: *const Session, position: model.ImportPosition) ?model.CapabilityRouteId {
    return self.imports.routeIdOf(position);
}

pub fn noteForeignRouteId(self: *Session, position: model.ImportPosition, route_id: model.CapabilityRouteId) !void {
    if (!self.holdsImport(position)) return Error.InvalidReference;
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
/// claim one wire retain; bootstrap is permanently held and claims none.
/// Session retains only scalar identity; Host owns its meaning and lifetime.
pub fn noteHostCapability(self: *Session, position: model.ImportPosition, ref: u64) !void {
    if (!self.holdsImport(position)) return Error.InvalidReference;
    return self.imports.noteHostRef(
        self.allocator,
        position,
        ref,
        @intFromBool(position.int() != BOOTSTRAP_POSITION),
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
