//! Position-keyed export/import rows with their ADR-0008 wire-delta counts.
//!
//! Name plate: `ExportTable` / `ImportTable` (over the shared `WireDeltaTable`
//! core). Not `slot.zig` (the CapTP `Slot` sum alone). CapTP keeps export,
//! import, and answer as separate position namespaces — answer rows live in
//! `answers/store.zig`; these tables own the export and import namespaces.
//!
//! An export row holds the authoritative `slot.Slot` for its position;
//! `Session.exportSlot` reads the cell rather than synthesizing a kind from
//! "row exists." An import row holds no cell: a far import is always
//! `remote_value` of its own position (`desc:export` names it regardless of
//! kind, ADR-0010, and remote mint is object-only, ADR-0080), so the row
//! records only who holds its retains.
//!
//! ## Two holders of one import row
//!
//! Every retain on an import is one the partner's wire mention granted, and
//! every one is released by exactly one outbound `op:gc-exports`. Which side
//! sends that release is the fact `ImportRow.session_held` keeps. A mention
//! the application received is the caller's to release, through
//! `Session.recordSend`. A mention the session itself consumed — the resolver a
//! V1.0 deliver advertised, the listener an `op:listen` nominated, the promise
//! a shortening callback advanced to — is released by the session's own
//! prepared message beside the callback, fire, or closure that spends it, and
//! `adoptForSession` marks it so at the moment the session takes it. A caller's
//! release is validated against `releasable`, the remainder, so it can never
//! address a row the session still has to settle through; the row's presence
//! at that later release is then an invariant, not a runtime question.
//!
//! ## Why a hash, not a raw `position -> row` vector
//!
//! Export positions are locally allocated and monotonic, so a flat index vector
//! would be safe and ideal for them. But import positions are *partner-
//! allocated*: an untrusted peer can name `import_position = 1 << 63`, and a raw
//! index vector would try to grow to that length — a memory DoS. An integer-
//! keyed hash keeps the O(1) win without letting a partner's sparse position
//! explode the backing store.
//!
//! ## No generational handles
//!
//! Export positions are ours: monotonic within a session and never reused, so
//! a bare position key suffices and no generation counter is carried.
//!
//! Import positions are not ours. The partner allocates them, and nothing in
//! the protocol stops it releasing one and reusing the number for a different
//! object. Every reader of an import position therefore depends on that
//! partner being monotonic, or on holding something besides the number.
//! Goblins is monotonic, so this is a dependence rather than a live defect —
//! but it is a dependence, not an absence of one, and the readers that carry
//! it should say so:
//!
//! - `ImportTable.identities` keeps a node-unique capability-route id per
//!   import row, and drops it when the row goes, so a reused position gets a
//!   fresh id rather than
//!   the previous object's.
//! - `Session.sturdyref_cache` drops every row for an import when its count
//!   reaches zero.
//! - `engine.Node.foreign_imports` validates its route id against the id kept
//!   on the live import row, and the Host release path retires the route. A
//!   released or reused position therefore fails an old id closed even if a
//!   low-level embedder has not reclaimed the stale map row yet.

const std = @import("std");
const model = @import("model");
const slot = @import("slot.zig");

pub const Slot = slot.Slot;

/// One live export position: CapTP cell + wire-delta count.
pub const ExportRow = struct {
    cell: Slot,
    count: u64,
};

/// One live import position. `count` is every wire retain the partner's
/// mentions granted; `session_held` is how many of those the session keeps
/// for a release it will put on the wire itself, never more than `count`.
pub const ImportRow = struct {
    count: u64,
    session_held: u64 = 0,
};

/// Wire-delta table (ADR-0008) keyed by CapTP position. Each position is
/// installed live at count 1 with its `Row`; the owning table's release verb
/// decrements by the wire delta and retires the row at zero. Underflow or an
/// unknown position is a loud error, never a silent clamp.
fn WireDeltaTable(comptime Row: type) type {
    return struct {
        rows: std.AutoHashMapUnmanaged(u64, Row) = .empty,

        const Self = @This();

        pub const Error = error{
            /// A decrement drove a count below zero, or named a position the table
            /// never held, surfaced loudly per ADR-0008 wire-delta accounting.
            GcUnderflow,
        };

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.rows.deinit(allocator);
        }

        /// Number of live positions, the row count the resilience caps bound.
        pub fn len(self: *const Self) usize {
            return self.rows.count();
        }

        pub fn contains(self: *const Self, position: u64) bool {
            return self.rows.contains(position);
        }

        /// Current refcount for `position`, or 0 if the position is not live.
        pub fn count(self: *const Self, position: u64) u64 {
            const row = self.rows.get(position) orelse return 0;
            return row.count;
        }

        /// Register `position` live with `fresh` if absent; idempotent no-op
        /// otherwise (existing row kept).
        pub fn register(self: *Self, allocator: std.mem.Allocator, position: u64, fresh: Row) !void {
            const gop = try self.rows.getOrPut(allocator, position);
            if (!gop.found_existing) gop.value_ptr.* = fresh;
        }

        /// Retain one wire reference to `position`: insert `fresh`, or increment
        /// an already-live row (everything but its count unchanged).
        pub fn retain(self: *Self, allocator: std.mem.Allocator, position: u64, fresh: Row) !void {
            const gop = try self.rows.getOrPut(allocator, position);
            if (gop.found_existing) {
                gop.value_ptr.count = std.math.add(u64, gop.value_ptr.count, 1) catch
                    return Error.GcUnderflow;
            } else {
                gop.value_ptr.* = fresh;
            }
        }

        /// Retain after capacity and refcount overflow were checked separately.
        pub fn retainAssumeCapacity(self: *Self, position: u64, fresh: Row) void {
            if (self.rows.getPtr(position)) |row| {
                std.debug.assert(row.count != std.math.maxInt(u64));
                row.count += 1;
                return;
            }
            self.rows.putAssumeCapacity(position, fresh);
        }

        /// Remove a row whose count reached zero.
        fn retire(self: *Self, position: u64) void {
            std.debug.assert(self.rows.get(position).?.count == 0);
            std.debug.assert(self.rows.remove(position));
        }
    };
}

/// Export rows: local-mint CapTP slots + wire-delta counts.
///
/// An export position is *locally allocated* (`Session.allocateExport`) and
/// monotonic, so its row count is bounded by our own sends; there is nothing a
/// partner can do to grow it without bound, and `register`/`retain` therefore
/// take no cap.
pub const ExportTable = struct {
    slots: WireDeltaTable(ExportRow) = .empty,

    pub const Id = model.ExportPosition;
    pub const Error = WireDeltaTable(ExportRow).Error;
    pub const empty: ExportTable = .{};

    pub fn deinit(self: *ExportTable, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
    }

    pub fn len(self: *const ExportTable) usize {
        return self.slots.len();
    }

    pub fn contains(self: *const ExportTable, position: Id) bool {
        return self.slots.contains(position.int());
    }

    pub fn count(self: *const ExportTable, position: Id) u64 {
        return self.slots.count(position.int());
    }

    pub fn slotOf(self: *const ExportTable, position: Id) ?Slot {
        const row = self.slots.rows.get(position.int()) orelse return null;
        return row.cell;
    }

    /// Reserve backing capacity for exports a prepared send may establish.
    /// Existing rows make an overestimate harmless; the caller's commit can
    /// then register and retain without allocating after authority moves.
    pub fn ensureUnusedCapacity(self: *ExportTable, allocator: std.mem.Allocator, additional: usize) !void {
        const count32 = std.math.cast(u32, additional) orelse return error.OutOfMemory;
        try self.slots.rows.ensureUnusedCapacity(allocator, count32);
    }

    /// Wire-held references to `position`: the refcount minus the local
    /// baseline every live export row carries. This is the most a partner's
    /// `op:gc-exports` may release — validating inbound GC against `count`
    /// instead would let a partner over-release delete the row and with it
    /// our own live capability.
    pub fn wireHeld(self: *const ExportTable, position: Id) u64 {
        const total = self.slots.count(position.int());
        return if (total == 0) 0 else total - 1;
    }

    /// What one inbound `op:gc-exports` may release, under the name the shared
    /// GC validator reads across both tables: every wire-held reference.
    pub const releasable = wireHeld;

    /// Install `position` as a near object (`local_value`) at count 1 if
    /// absent; idempotent otherwise.
    pub fn register(self: *ExportTable, allocator: std.mem.Allocator, position: Id) !void {
        return self.slots.register(allocator, position.int(), .{ .cell = .{ .local_value = position.int() }, .count = 1 });
    }

    /// Install `position` with an explicit local-mint cell (object or promise).
    pub fn registerCell(self: *ExportTable, allocator: std.mem.Allocator, position: Id, cell: Slot) !void {
        std.debug.assert(slot.mintOf(cell) == .local);
        std.debug.assert(slot.position(cell) == position.int());
        return self.slots.register(allocator, position.int(), .{ .cell = cell, .count = 1 });
    }

    /// Install `position` as a local *promise* (`local_unresolved`) at count 1
    /// if absent; idempotent otherwise. The promise twin of `register`: a
    /// resolver export is minted unresolved at allocation, so its slot is
    /// authoritative before any wire mention projects it (ADR-0080).
    pub fn registerPromise(self: *ExportTable, allocator: std.mem.Allocator, position: Id) !void {
        return self.slots.register(allocator, position.int(), .{ .cell = .{ .local_unresolved = position.int() }, .count = 1 });
    }

    /// Take one wire reference — or one explicit addressability grant — on a
    /// live export row. Callers install the local baseline first (`register`),
    /// so every export row's count stays baseline plus wire-held; retaining an
    /// absent row would mint a baseline-less count that `wireHeld` misreads,
    /// hence the assert.
    pub fn retain(self: *ExportTable, allocator: std.mem.Allocator, position: Id) !void {
        std.debug.assert(self.slots.contains(position.int()));
        return self.slots.retain(allocator, position.int(), .{ .cell = .{ .local_value = position.int() }, .count = 1 });
    }

    /// Decrement `position` by `delta`, retiring the row at zero. Underflow, or
    /// an unknown position with `delta > 0`, is `Error.GcUnderflow`.
    pub fn decrement(self: *ExportTable, position: Id, delta: u64) Error!void {
        const row = self.slots.rows.getPtr(position.int()) orelse {
            if (delta == 0) return;
            return Error.GcUnderflow;
        };
        if (delta > row.count) return Error.GcUnderflow;
        row.count -= delta;
        if (row.count == 0) self.slots.retire(position.int());
    }
};

/// Import rows: wire-delta counts split by holder, plus optional identities.
///
/// Unlike an export, an import position is partner-allocated, so an untrusted peer
/// could introduce unboundedly many distinct imports. `retain` therefore takes a
/// `max` and refuses a *new* id past it (ADR-0025), so the cap is enforced at the
/// one place a row is added rather than at each call site. An already-held id is
/// a refcount bump and never trips the cap, because it adds no row. There is no
/// `register`: imports are only ever retained.
pub const ImportTable = struct {
    slots: WireDeltaTable(ImportRow) = .empty,
    /// Optional identities attached to live import rows: the Node routing
    /// route id (ADR-0069) and the opaque Host capability id (ADR-0096). Both die
    /// with the import row, so partner reuse of one numeric position cannot
    /// revive either identity. One optional map preserves the one-word empty
    /// session cost while the two layer-specific identities coexist; the map
    /// is bounded by the import table's own cap.
    identities: ?*IdentityMap = null,

    const Identity = struct {
        // Both namespaces reserve zero, so scalar sentinels avoid optional-u64
        // tags; the third word accounts claimed Host/wire retains.
        node_route_id: u64 = 0,
        host_ref: u64 = 0,
        /// Number of this row's wire retains already surfaced as Host handles.
        /// Lift may consume each wire retain once; local copies of one borrowed
        /// reference cannot manufacture matching GC authority.
        lifted_retains: u64 = 0,
    };
    const identity_budget_bytes: usize = 24;
    comptime {
        if (@sizeOf(Identity) > identity_budget_bytes) @compileError("import identity memo exceeded its three-word retained-row budget");
    }
    pub const IdentityMap = std.AutoHashMapUnmanaged(u64, Identity);
    pub const Id = model.ImportPosition;
    pub const Error = WireDeltaTable(ImportRow).Error;
    /// Adding a new import row can hit the partner-import cap; everything else
    /// an import table does (decrement, lookup) shares the wire-delta errors.
    pub const RetainError = std.mem.Allocator.Error || Error || error{ImportCapExceeded};
    pub const empty: ImportTable = .{};

    pub fn deinit(self: *ImportTable, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
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
    pub fn abandonRouteId(self: *ImportTable, position: Id, route_id: model.CapabilityRouteId) void {
        const map = self.identities orelse unreachable;
        const identity = map.getPtr(position.int()) orelse unreachable;
        std.debug.assert(identity.node_route_id == route_id.int());
        identity.node_route_id = 0;
        if (identity.host_ref == 0 and identity.lifted_retains == 0)
            std.debug.assert(map.remove(position.int()));
    }

    /// Opaque Host capability currently naming this live import incarnation.
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
    /// whose authority is permanent for the session and never wire-GCed.
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
    /// may already be gone after GC; in that case its memo died with it.
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

    pub fn len(self: *const ImportTable) usize {
        return self.slots.len();
    }

    pub fn contains(self: *const ImportTable, position: Id) bool {
        return self.slots.contains(position.int());
    }

    /// Every wire retain on `position`, whoever holds it, or 0 if not live.
    pub fn count(self: *const ImportTable, position: Id) u64 {
        return self.slots.count(position.int());
    }

    /// How many of `position`'s retains the session keeps for its own release.
    pub fn sessionHeld(self: *const ImportTable, position: Id) u64 {
        const row = self.slots.rows.get(position.int()) orelse return 0;
        return row.session_held;
    }

    /// What one caller's outbound `op:gc-exports` may release, under the name
    /// the shared GC validator reads across both tables: the retains the
    /// session is not keeping for a release of its own.
    pub fn releasable(self: *const ImportTable, position: Id) u64 {
        const row = self.slots.rows.get(position.int()) orelse return 0;
        return row.count - row.session_held;
    }

    /// Retain one wire reference to a partner-introduced import. A *new* id is
    /// bounded by `max` (`SessionLimits.max_imports`); an already-held id only
    /// increments its wire-delta refcount and is never refused, since a partner
    /// may reference the same export repeatedly and our later `op:gc-exports`
    /// must release the same total delta.
    pub fn retain(self: *ImportTable, allocator: std.mem.Allocator, position: Id, max: usize) RetainError!void {
        if (!self.slots.contains(position.int()) and self.slots.len() >= max) {
            return error.ImportCapExceeded;
        }
        return self.slots.retain(allocator, position.int(), .{ .count = 1 });
    }

    /// Reserve one retain without changing authority. A fresh partner-chosen
    /// position is cap-checked here; an existing row is checked for wire-delta
    /// overflow. `retainAssumeCapacity` is then infallible at commit.
    pub fn prepareRetain(
        self: *ImportTable,
        allocator: std.mem.Allocator,
        position: Id,
        max: usize,
    ) RetainError!void {
        if (self.slots.contains(position.int())) {
            if (self.slots.count(position.int()) == std.math.maxInt(u64))
                return error.GcUnderflow;
            return;
        }
        if (self.slots.len() >= max) return error.ImportCapExceeded;
        try self.slots.rows.ensureUnusedCapacity(allocator, 1);
    }

    /// Reserve rows for a validated batch of distinct new imports. The
    /// validation walk has already enforced `max_imports`; this function owns
    /// only the backing allocation needed to make the later mention-by-mention
    /// retain pass infallible.
    pub fn ensureUnusedCapacity(
        self: *ImportTable,
        allocator: std.mem.Allocator,
        additional: usize,
    ) !void {
        const count32 = std.math.cast(u32, additional) orelse return error.OutOfMemory;
        try self.slots.rows.ensureUnusedCapacity(allocator, count32);
    }

    /// Commit one retain after `prepareRetain` and before any intervening
    /// insertion into this table.
    pub fn retainAssumeCapacity(self: *ImportTable, position: Id) void {
        self.slots.retainAssumeCapacity(position.int(), .{ .count = 1 });
    }

    /// Take one of `position`'s counted retains as the session's own: it will
    /// leave through the session's prepared release and no caller may spend
    /// it. The row must be live with a retain left to adopt; both are
    /// invariants of the seams that adopt, which retained in the same turn.
    pub fn adoptForSession(self: *ImportTable, position: Id) void {
        const row = self.slots.rows.getPtr(position.int()) orelse unreachable;
        std.debug.assert(row.session_held < row.count);
        row.session_held += 1;
    }

    /// A caller's release of `delta` retains, retiring the row at zero. Past
    /// `releasable`, or an unknown position with `delta > 0`, is
    /// `Error.GcUnderflow`.
    pub fn decrement(self: *ImportTable, position: Id, delta: u64) Error!void {
        const row = self.slots.rows.getPtr(position.int()) orelse {
            if (delta == 0) return;
            return Error.GcUnderflow;
        };
        if (delta > row.count - row.session_held) return Error.GcUnderflow;
        row.count -= delta;
        if (row.count == 0) self.retire(position);
    }

    /// The session's release of `delta` of its own retains, retiring the row
    /// at zero. Infallible: the session adopted what it releases.
    pub fn releaseSessionHeld(self: *ImportTable, position: Id, delta: u64) void {
        const row = self.slots.rows.getPtr(position.int()) orelse unreachable;
        std.debug.assert(delta <= row.session_held);
        row.session_held -= delta;
        row.count -= delta;
        if (row.count == 0) self.retire(position);
    }

    fn retire(self: *ImportTable, position: Id) void {
        self.slots.retire(position.int());
        if (self.identities) |map| {
            // Tolerant: only an identity-bearing import has a memo to drop.
            if (map.contains(position.int())) std.debug.assert(map.remove(position.int()));
        }
    }

    fn identityMap(self: *ImportTable, allocator: std.mem.Allocator) !*IdentityMap {
        return self.identities orelse map: {
            const fresh = try allocator.create(IdentityMap);
            fresh.* = .empty;
            self.identities = fresh;
            break :map fresh;
        };
    }
};
