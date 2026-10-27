//! Import rows: the positions the partner mints, with their ADR-0004
//! wire-delta counts split by holder, hashed under the session's secret.
//!
//! Name plate: `ImportTable`. Not `slot.zig` (the CapTP `Slot` sum alone) and
//! not `export_table.zig` (the positions this session mints). An import row
//! holds no cell: a far import is always `remote_value` of its own position
//! (`desc:export` names it regardless of kind, ADR-0006, and remote mint is
//! object-only, ADR-0006), so the row records only who holds its retains.
//!
//! ## Two holders of one import row
//!
//! Every retain on an import is one the partner's wire mention granted, and
//! every one is released by exactly one outbound `op:gc-exports`. Which side
//! sends that release is the fact `ImportRow.session_held` keeps. A mention
//! the application received is the caller's to release, through
//! `Session.recordSend`. A mention the session itself consumed, the resolver a
//! V1.0 deliver advertised, the listener an `op:listen` nominated, the promise
//! a shortening callback advanced to, is released by the session's own
//! prepared message beside the callback, fire, or closure that spends it, and
//! `adoptForSession` marks it so at the moment the session takes it. A caller's status-allow: state at observation
//! release is validated against `releasable`, the remainder, so it can never
//! address a row the session still has to settle through. The row's presence
//! at that later release is then an invariant, not a runtime question.
//!
//! ## A stored resolution holds what it names
//!
//! A resolution this side sent stays stored for the answer's lifetime, and a
//! late call, listen, or projection forwards to the partner objects it names.
//! Each stored resolution therefore holds every import it names
//! (`holdForResolution`), and no release of a held row reaches the wire: the
//! producer leaves the entry out of its frame (`Session.wireRelease`) and the
//! table keeps the retains when the release records, a caller's as the
//! session's (`decrement`) and the session's as held back (`releaseSessionHeld`).
//! A mention a forwarded reply introduced has no caller, so the session parks
//! it behind the hold at the store (`parkForResolution`). They leave on the
//! wire when the last hold does (`releaseResolutionHold`).
//! The row cannot retire while held, so the partner cannot reuse the position
//! under the stored value. A Host handle lifted from the stored value while
//! every retain is held back takes one back (`noteHostRef`), so its release
//! is a caller's release again.
//!
//! ## A hashed table for the partner's positions
//!
//! An untrusted peer can name `import_position = 1 << 63`, and a vector would
//! try to grow to it, so the table hashes positions under the session's
//! secret multiplier (ADR-0037). Nothing in the protocol stops a partner
//! releasing an import position and reusing the number for a different
//! object, so every reader of an import position holds something besides the
//! number:
//!
//! - `ImportTable.identities` keeps a node-unique capability-route id per
//!   import row, and drops it when the row goes, so a reused position gets a
//!   fresh id rather than the previous object's.
//! - `Session.sturdyref_cache` drops every row for an import when its count
//!   reaches zero.
//! - `engine.Node.foreign_imports` validates its route id against the id kept
//!   on the live import row, and the Host release path retires the route. A
//!   released or reused position therefore fails an old id closed even if a
//!   low-level embedder has not reclaimed the stale map row yet. status-allow: pending state or quoted runtime label
const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");

/// One live import position. `count` is every wire retain the partner's
/// mentions granted. `session_held` is how many of those the session keeps
/// for a release it will put on the wire itself, never more than `count`.
/// `held_back` is the part of `session_held` a stored resolution's hold keeps
/// back, released by a caller or parked for a mention no caller owns, owed to
/// the wire when the last hold leaves. `resolution_holds` counts the
/// stored-resolution mentions holding the row.
pub const ImportRow = struct {
    count: u64,
    session_held: u64 = 0,
    held_back: u64 = 0,
    resolution_holds: u64 = 0,
};

/// Import rows: wire-delta counts split by holder, plus optional identities.
///
/// Unlike an export, an import position is partner-allocated, so an untrusted peer
/// could introduce unboundedly many distinct imports. `retain` therefore takes a
/// `max` and refuses a *new* id past it (ADR-0008), so the cap is enforced at the
/// one place a row is added rather than at each call site. An already-held id is
/// a refcount bump and never trips the cap, because it adds no row. There is no
/// `register`: imports are only ever retained.
pub const ImportTable = struct {
    /// Live rows keyed by the partner's position (ADR-0004). A row is
    /// installed at count 1, a release decrements by the wire delta and
    /// retires the row at zero, and underflow, overflow, or an unknown
    /// position is a loud error, never a silent clamp.
    rows: foundation.identity_hash.MapOf(.wire, u64, ImportRow),
    /// Optional identities attached to live import rows: the Node routing
    /// route id and the opaque Host capability id (ADR-0026). Both die
    /// with the import row, so partner reuse of one numeric position cannot
    /// revive either identity. One optional map preserves the one-word empty
    /// session cost while the two layer-specific identities coexist. The map
    /// is bounded by the import table's own cap.
    identities: ?*IdentityMap = null,
    /// How many live rows a stored resolution holds, so a release on a
    /// session with no hold anywhere decides without a lookup per entry.
    held_rows: u64 = 0,

    const Identity = struct {
        // Both namespaces reserve zero, so scalar sentinels avoid optional-u64
        // tags; the third word accounts claimed Host/wire retains.
        node_route_id: u64 = 0,
        host_ref: u64 = 0,
        /// Number of this row's wire retains already surfaced as Host handles.
        /// Lift may consume each wire retain once. Local copies of one borrowed
        /// reference cannot manufacture matching GC authority.
        lifted_retains: u64 = 0,
    };
    const identity_budget_bytes: usize = 24;
    comptime {
        if (@sizeOf(Identity) > identity_budget_bytes) @compileError("import identity memo exceeded its three-word retained-row budget");
    }
    pub const IdentityMap = foundation.identity_hash.MapOf(.wire, u64, Identity);
    pub const Id = model.ImportPosition;
    pub const Error = error{
        /// A decrement drove a count below zero, or named a position the
        /// table never held, surfaced loudly per ADR-0004 wire-delta
        /// accounting.
        GcUnderflow,
        /// A retain would carry a count past what its `u64` holds.
        GcOverflow,
    };
    /// Adding a new import row can hit the partner-import cap. Everything else
    /// an import table does (decrement, lookup) shares the wire-delta errors.
    pub const RetainError = std.mem.Allocator.Error || Error || error{ImportCapExceeded};

    /// An import position is the peer's export position, so the table hashes
    /// under the session's wire multiplier.
    pub fn keyed(wire_hash_multiplier: u64) ImportTable {
        return .{ .rows = .keyed(wire_hash_multiplier) };
    }

    /// Key an empty table under the session's secret.
    pub fn keyWire(self: *ImportTable, wire_hash_multiplier: u64) void {
        std.debug.assert(self.identities == null);
        self.rows.keyWire(wire_hash_multiplier);
    }

    pub fn deinit(self: *ImportTable, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        if (self.identities) |map| {
            map.deinit(allocator);
            allocator.destroy(map);
            self.identities = null;
        }
    }

    /// The node-unique capability route `position` was enrolled under, or null.
    pub fn routeIdOf(self: *const ImportTable, position: Id) ?model.CapabilityRouteId {
        const map = self.identities orelse return null;
        const id = (map.get(position.int()) orelse return null).node_route_id;
        return if (id == 0) null else .from(id);
    }

    /// Record the route id for one import the Session has already proved held.
    /// The permanently held bootstrap import has no slot row but uses this same
    /// identity map, so ordinary and bootstrap routes share one O(1) memo.
    pub fn noteRouteId(self: *ImportTable, allocator: std.mem.Allocator, position: Id, route_id: model.CapabilityRouteId) !void {
        const map = try self.identityMap(allocator);
        const gop = try map.getOrPut(allocator, position.int());
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.node_route_id = route_id.int();
    }

    /// Undo a route enrollment that never became observable. The import row
    /// remains authoritative and any Host identity attached beside the route id
    /// is preserved. Retained map capacity is intentional high-water storage.
    /// Presence is certain because `noteRouteId` in the same commit/rollback
    /// pair created the map and row for this position, behind the
    /// `holdsImport` gate `noteForeignRouteId` checks first.
    pub fn abandonRouteId(self: *ImportTable, position: Id, route_id: model.CapabilityRouteId) void {
        const map = self.identities orelse unreachable;
        const identity = map.getPtr(position.int()) orelse unreachable;
        std.debug.assert(identity.node_route_id == route_id.int());
        identity.node_route_id = 0;
        if (identity.host_ref == 0 and identity.lifted_retains == 0)
            std.debug.assert(map.remove(position.int()));
    }

    /// Opaque Host capability naming this live import incarnation.
    pub fn hostRefOf(self: *const ImportTable, position: Id) ?u64 {
        const map = self.identities orelse return null;
        const ref = (map.get(position.int()) orelse return null).host_ref;
        return if (ref == 0) null else ref;
    }

    pub const HostIdentity = struct { ref: u64, lifted_retains: u64 };

    /// Host identity and claimed wire-retain count for this live import.
    pub fn hostIdentityOf(self: *const ImportTable, position: Id) ?HostIdentity {
        const map = self.identities orelse return null;
        const identity = map.get(position.int()) orelse return null;
        if (identity.host_ref == 0) return null;
        return .{ .ref = identity.host_ref, .lifted_retains = identity.lifted_retains };
    }

    /// Attach `host_ref` to an import the Session has already proved held.
    /// `wire_retains` is one for an introduced import and zero for bootstrap,
    /// whose authority is permanent for the session and never wire-GCed. The
    /// one retain is a caller's: a row whose every retain is held back for a
    /// stored resolution, released or parked, gives one back to the handle,
    /// whose release is then held back in turn.
    pub fn noteHostRef(
        self: *ImportTable,
        allocator: std.mem.Allocator,
        position: Id,
        host_ref: u64,
        wire_retains: u64,
    ) !void {
        const map = try self.identityMap(allocator);
        const gop = try map.getOrPut(allocator, position.int());
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (wire_retains != 0) {
            const row = self.liveRow(position);
            if (row.count == row.session_held and row.held_back != 0) {
                row.session_held -= 1;
                row.held_back -= 1;
            }
        }
        gop.value_ptr.host_ref = host_ref;
        gop.value_ptr.lifted_retains = wire_retains;
    }

    /// Claim one more wire retain for an already-canonical Host identity. Only
    /// a caller-releasable retain can be lifted: the Host's release of the
    /// handle is a caller's `op:gc-exports`, which never spends a session-held
    /// one.
    pub fn claimHostRetain(self: *ImportTable, position: Id, host_ref: u64) !void {
        const map = self.identities orelse return error.UnknownImport;
        const identity = map.getPtr(position.int()) orelse return error.UnknownImport;
        if (identity.host_ref != host_ref) return error.UnknownImport;
        if (identity.lifted_retains >= self.releasable(position)) return error.NoUnliftedImportRetain;
        identity.lifted_retains += 1;
    }

    /// Return claimed Host retains as their handles are released. The wire row
    /// may already be gone after GC. In that case its memo died with it.
    pub fn releaseHostRetains(self: *ImportTable, position: Id, host_ref: u64, delta: u64) void {
        const map = self.identities orelse return;
        const identity = map.getPtr(position.int()) orelse return;
        if (identity.host_ref != host_ref) return;
        std.debug.assert(delta <= identity.lifted_retains);
        identity.lifted_retains -= delta;
    }

    /// Remove the Host identity only if it is still the expected incarnation.
    /// A Node route id sharing the row remains intact.
    pub fn forgetHostRef(self: *ImportTable, position: Id, host_ref: u64) void {
        const map = self.identities orelse return;
        const identity = map.getPtr(position.int()) orelse return;
        if (identity.host_ref != host_ref) return;
        identity.host_ref = 0;
        identity.lifted_retains = 0;
        if (identity.node_route_id == 0) std.debug.assert(map.remove(position.int()));
    }

    /// Number of live positions, the row count the resilience caps bound.
    pub fn len(self: *const ImportTable) usize {
        return self.rows.count();
    }

    pub fn contains(self: *const ImportTable, position: Id) bool {
        return self.rows.contains(position.int());
    }

    /// Every wire retain on `position`, whoever holds it, or 0 if not live.
    pub fn count(self: *const ImportTable, position: Id) u64 {
        const row = self.rows.get(position.int()) orelse return 0;
        return row.count;
    }

    /// How many of `position`'s retains the session keeps for its own release.
    pub fn sessionHeld(self: *const ImportTable, position: Id) u64 {
        const row = self.rows.get(position.int()) orelse return 0;
        return row.session_held;
    }

    /// What one caller's outbound `op:gc-exports` may release, under the name
    /// the shared GC validator reads across both tables: the retains the
    /// session is not keeping for a release of its own.
    pub fn releasable(self: *const ImportTable, position: Id) u64 {
        const row = self.rows.get(position.int()) orelse return 0;
        return row.count - row.session_held;
    }

    /// Retain one wire reference to a partner-introduced import. A *new* id is
    /// bounded by `max` (`SessionLimits.max_imports`). An already-held id only
    /// increments its wire-delta refcount, refused only at `GcOverflow`, since
    /// a partner may reference the same export repeatedly and our later
    /// `op:gc-exports` must release the same total delta.
    pub fn retain(self: *ImportTable, allocator: std.mem.Allocator, position: Id, max: usize) RetainError!void {
        if (!self.rows.contains(position.int()) and self.rows.count() >= max) {
            return error.ImportCapExceeded;
        }
        const gop = try self.rows.getOrPut(allocator, position.int());
        if (gop.found_existing) {
            gop.value_ptr.count = std.math.add(u64, gop.value_ptr.count, 1) catch
                return error.GcOverflow;
        } else {
            gop.value_ptr.* = .{ .count = 1 };
        }
    }

    /// Reserve one retain without changing authority. A fresh partner-chosen
    /// position is cap-checked here. An existing row is checked for wire-delta
    /// overflow. `retainAssumeCapacity` is then infallible at commit.
    pub fn prepareRetain(
        self: *ImportTable,
        allocator: std.mem.Allocator,
        position: Id,
        max: usize,
    ) RetainError!void {
        if (self.rows.get(position.int())) |row| {
            if (row.count == std.math.maxInt(u64)) return error.GcOverflow;
            return;
        }
        if (self.rows.count() >= max) return error.ImportCapExceeded;
        try self.rows.ensureUnusedCapacity(allocator, 1);
    }

    /// Reserve rows for a validated batch of distinct new imports. The
    /// validation walk has already enforced `max_imports`. This function owns
    /// only the backing allocation needed to make the later mention-by-mention
    /// retain pass infallible.
    pub fn ensureUnusedCapacity(
        self: *ImportTable,
        allocator: std.mem.Allocator,
        additional: usize,
    ) !void {
        const count32 = std.math.cast(u32, additional) orelse return error.OutOfMemory;
        try self.rows.ensureUnusedCapacity(allocator, count32);
    }

    /// Commit one retain after `prepareRetain` and before any intervening
    /// insertion into this table.
    pub fn retainAssumeCapacity(self: *ImportTable, position: Id) void {
        if (self.rows.getPtr(position.int())) |row| {
            std.debug.assert(row.count != std.math.maxInt(u64));
            row.count += 1;
            return;
        }
        self.rows.putAssumeCapacity(position.int(), .{ .count = 1 });
    }

    /// The live row behind the session's own adopts and releases. Presence is
    /// certain because the adopting seams retained in the same turn:
    /// `retainImportForSession` retains then adopts in one call, and
    /// `adoptImportRetain`'s same-turn retainers (a V1.0 deliver's resolver, a
    /// shortening callback's advanced-to promise) retained through
    /// `ImportTable.retain`, and `parkForResolution` runs in the dispatch
    /// that registered the reply's mentions. The session's release spends
    /// only what it adopted (`applySessionImportRelease`,
    /// `releaseSessionImportRetain`).
    fn liveRow(self: *ImportTable, position: Id) *ImportRow {
        return self.rows.getPtr(position.int()) orelse unreachable;
    }

    /// Take one of `position`'s counted retains as the session's own: it will
    /// leave through the session's prepared release and no caller may spend
    /// it. The row must be live with a retain left to adopt. Both are
    /// invariants of the seams that adopt, which retained in the same turn.
    pub fn adoptForSession(self: *ImportTable, position: Id) void {
        const row = self.liveRow(position);
        std.debug.assert(row.session_held < row.count);
        row.session_held += 1;
    }

    /// One more stored-resolution mention holds `position`. The row is live:
    /// the resolution was validated against this table before it was stored.
    pub fn holdForResolution(self: *ImportTable, position: Id) void {
        const row = self.liveRow(position);
        if (row.resolution_holds == 0) self.held_rows += 1;
        row.resolution_holds += 1;
    }

    /// The session takes one retain on a held `position` that no caller
    /// releases, a mention a forwarded reply introduced for the stored
    /// resolution, and owes it to the wire when the row's last hold leaves.
    pub fn parkForResolution(self: *ImportTable, position: Id) void {
        const row = self.liveRow(position);
        std.debug.assert(row.resolution_holds != 0);
        std.debug.assert(row.session_held < row.count);
        row.session_held += 1;
        row.held_back += 1;
    }

    /// Whether a stored resolution holds `position`. False for a row that
    /// is not live.
    pub fn heldByResolution(self: *const ImportTable, position: Id) bool {
        if (self.held_rows == 0) return false;
        return self.resolutionHolds(position) != 0;
    }

    /// One stored-resolution mention of `position` left. Returns the retains
    /// held back for callers once no hold remains, which the caller releases
    /// through `releaseSessionHeld` beside the wire message, or zero while
    /// another hold keeps them.
    pub fn releaseResolutionHold(self: *ImportTable, position: Id) u64 {
        const row = self.liveRow(position);
        std.debug.assert(row.resolution_holds != 0);
        row.resolution_holds -= 1;
        if (row.resolution_holds != 0) return 0;
        self.held_rows -= 1;
        const owed = row.held_back;
        row.held_back = 0;
        return owed;
    }

    /// How many stored-resolution mentions hold `position`, or 0 if not live.
    pub fn resolutionHolds(self: *const ImportTable, position: Id) u64 {
        const row = self.rows.get(position.int()) orelse return 0;
        return row.resolution_holds;
    }

    /// A caller's release of `delta` retains, retiring the row at zero. Past
    /// `releasable`, or an unknown position with `delta > 0`, is
    /// `Error.GcUnderflow`. On a held row the retains stay, as the session's
    /// and held back, because the producer left this entry off the wire.
    pub fn decrement(self: *ImportTable, position: Id, delta: u64) Error!void {
        const row = self.rows.getPtr(position.int()) orelse {
            if (delta == 0) return;
            return error.GcUnderflow;
        };
        if (delta > row.count - row.session_held) return error.GcUnderflow;
        if (row.resolution_holds != 0) {
            row.session_held += delta;
            row.held_back += delta;
            return;
        }
        row.count -= delta;
        if (row.count == 0) self.retire(position);
    }

    /// Undo a retain `registerImport` took in the same dispatch, before any
    /// store could hold the row. A row that reaches zero retires.
    pub fn rollbackRetain(self: *ImportTable, position: Id) void {
        const row = self.liveRow(position);
        std.debug.assert(row.count > row.session_held);
        row.count -= 1;
        if (row.count == 0) {
            std.debug.assert(row.resolution_holds == 0);
            self.retire(position);
        }
    }

    /// The session's release of `delta` of its own retains, retiring the row
    /// at zero. Infallible: the session adopted what it releases. On a held
    /// row the retains stay held back, because the producer left this entry
    /// off the wire.
    pub fn releaseSessionHeld(self: *ImportTable, position: Id, delta: u64) void {
        const row = self.liveRow(position);
        std.debug.assert(delta <= row.session_held);
        if (row.resolution_holds != 0) {
            std.debug.assert(delta <= row.session_held - row.held_back);
            row.held_back += delta;
            return;
        }
        row.session_held -= delta;
        row.count -= delta;
        if (row.count == 0) self.retire(position);
    }

    /// Remove a row whose count reached zero, with any identity memo on it.
    fn retire(self: *ImportTable, position: Id) void {
        std.debug.assert(self.rows.get(position.int()).?.count == 0);
        std.debug.assert(self.rows.remove(position.int()));
        // tolerant: only an identity-bearing import has a memo to drop.
        if (self.identities) |map| _ = map.remove(position.int());
    }

    fn identityMap(self: *ImportTable, allocator: std.mem.Allocator) !*IdentityMap {
        return self.identities orelse map: {
            const fresh = try allocator.create(IdentityMap);
            fresh.* = .keyed(self.rows.multiplier);
            self.identities = fresh;
            break :map fresh;
        };
    }
};
