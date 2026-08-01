//! Position-keyed export/import rows: CapTP `Slot` cell + wire-delta count.
//!
//! Name plate: `ExportTable` / `ImportTable` (and their shared `SlotTable`
//! core). Not `slot.zig` (the CapTP `Slot` sum alone). CapTP keeps export,
//! import, and answer as separate position namespaces — answer rows live in
//! `answers.zig`; these tables own the export and import namespaces.
//!
//! Each live row holds the authoritative `slot.Slot` for that position plus the
//! ADR-0008 wire-delta refcount. `Session.exportSlot` / `importSlot` read the
//! cell; they do not synthesize a kind from "row exists."
//!
//! ## Why a hash, not a raw `position -> row` vector
//!
//! Export positions are locally allocated and monotonic, so a flat index vector
//! would be safe and ideal for them. But import positions are *partner-
//! allocated*: a hostile peer can name `import_position = 1 << 63`, and a raw
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
//! - `ImportTable.tokens` keeps a node-unique token per import row, and drops
//!   it when the row goes, so a reused position gets a fresh token rather than
//!   the previous object's.
//! - `Session.sturdyref_cache` drops every row for an import when its count
//!   reaches zero.
//! - `engine.Node.foreign_imports` validates its token against the token kept
//!   on the live import row, and the Host release path retires the route. A
//!   released or reused position therefore fails an old token closed even if a
//!   low-level embedder has not reclaimed the stale map row yet.

const std = @import("std");
const model = @import("model");
const slot = @import("slot.zig");

pub const Slot = slot.Slot;

/// One live position: CapTP cell + wire-delta count.
pub const Entry = struct {
    cell: Slot,
    count: u64,
};

/// Wire-delta table (ADR-0008) keyed by CapTP position. Each position is
/// installed live at count 1 with its `Slot` cell; `op:gc-*` decrements by the
/// wire delta and the row is removed at zero. Underflow or an unknown position
/// is a loud error, never a silent clamp.
const SlotTable = struct {
    rows: std.AutoHashMapUnmanaged(u64, Entry) = .empty,

    pub const Error = error{
        /// A decrement drove a count below zero, or named a position the table
        /// never held, surfaced loudly per ADR-0008 wire-delta accounting.
        GcUnderflow,
    };

    pub const empty: SlotTable = .{};

    pub fn deinit(self: *SlotTable, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
    }

    /// Number of live positions, the row count the resilience caps bound.
    pub fn len(self: *const SlotTable) usize {
        return self.rows.count();
    }

    pub fn contains(self: *const SlotTable, position: u64) bool {
        return self.rows.contains(position);
    }

    /// Current refcount for `position`, or 0 if the position is not live.
    pub fn count(self: *const SlotTable, position: u64) u64 {
        const entry = self.rows.get(position) orelse return 0;
        return entry.count;
    }

    /// CapTP cell for `position`, or null if not live.
    pub fn cell(self: *const SlotTable, position: u64) ?Slot {
        const entry = self.rows.get(position) orelse return null;
        return entry.cell;
    }

    /// Register `position` live at count 1 with `new_cell` if absent;
    /// idempotent no-op otherwise (existing cell and count kept).
    pub fn register(self: *SlotTable, allocator: std.mem.Allocator, position: u64, new_cell: Slot) !void {
        const gop = try self.rows.getOrPut(allocator, position);
        if (!gop.found_existing) gop.value_ptr.* = .{ .cell = new_cell, .count = 1 };
    }

    /// Retain one wire reference to `position`: insert at count 1 with
    /// `cell_if_new`, or increment an already-live row (cell unchanged).
    pub fn retain(self: *SlotTable, allocator: std.mem.Allocator, position: u64, cell_if_new: Slot) !void {
        const gop = try self.rows.getOrPut(allocator, position);
        if (gop.found_existing) {
            gop.value_ptr.count += 1;
        } else {
            gop.value_ptr.* = .{ .cell = cell_if_new, .count = 1 };
        }
    }

    /// Decrement `position` by `delta`, removing the row at zero. Underflow, or
    /// an unknown position with `delta > 0`, returns `Error.GcUnderflow`.
    pub fn decrement(self: *SlotTable, position: u64, delta: u64) Error!void {
        const entry = self.rows.getPtr(position) orelse {
            if (delta == 0) return;
            return Error.GcUnderflow;
        };
        if (delta > entry.count) return Error.GcUnderflow;
        entry.count -= delta;
        if (entry.count == 0) std.debug.assert(self.rows.remove(position));
    }
};

/// Export rows: local-mint CapTP slots + wire-delta counts.
///
/// An export position is *locally allocated* (`Session.allocateExport`) and
/// monotonic, so its row count is bounded by our own sends; there is nothing a
/// partner can do to grow it without bound, and `register`/`retain` therefore
/// take no cap.
pub const ExportTable = struct {
    slots: SlotTable = .empty,

    pub const Id = model.ExportPosition;
    pub const Error = SlotTable.Error;
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
        return self.slots.cell(position.int());
    }

    /// Wire-held references to `position`: the refcount minus the local
    /// baseline every live export row carries. This is the most a partner's
    /// `op:gc-exports` may release — validating inbound GC against `count`
    /// instead would let a hostile over-release delete the row and with it
    /// our own live capability.
    pub fn wireHeld(self: *const ExportTable, position: Id) u64 {
        const total = self.slots.count(position.int());
        return if (total == 0) 0 else total - 1;
    }

    /// Install `position` as a near object (`local_value`) at count 1 if
    /// absent; idempotent otherwise.
    pub fn register(self: *ExportTable, allocator: std.mem.Allocator, position: Id) !void {
        return self.slots.register(allocator, position.int(), .{ .local_value = position.int() });
    }

    /// Install `position` with an explicit local-mint cell (object or promise).
    pub fn registerCell(self: *ExportTable, allocator: std.mem.Allocator, position: Id, cell: Slot) !void {
        std.debug.assert(slot.mintOf(cell) == .local);
        std.debug.assert(slot.position(cell) == position.int());
        return self.slots.register(allocator, position.int(), cell);
    }

    /// Install `position` as a local *promise* (`local_unresolved`) at count 1
    /// if absent; idempotent otherwise. The promise twin of `register`: a
    /// resolver export is minted unresolved at allocation, so its slot is
    /// authoritative before any wire mention projects it (ADR-0080).
    pub fn registerPromise(self: *ExportTable, allocator: std.mem.Allocator, position: Id) !void {
        return self.slots.register(allocator, position.int(), .{ .local_unresolved = position.int() });
    }

    /// Take one wire reference — or one explicit addressability grant — on a
    /// live export row. Callers install the local baseline first (`register`),
    /// so every export row's count stays baseline plus wire-held; retaining an
    /// absent row would mint a baseline-less count that `wireHeld` misreads,
    /// hence the assert.
    pub fn retain(self: *ExportTable, allocator: std.mem.Allocator, position: Id) !void {
        std.debug.assert(self.slots.contains(position.int()));
        return self.slots.retain(allocator, position.int(), .{ .local_value = position.int() });
    }

    pub fn decrement(self: *ExportTable, position: Id, delta: u64) Error!void {
        return self.slots.decrement(position.int(), delta);
    }
};

/// Import rows: remote-mint CapTP slots + wire-delta counts.
///
/// Unlike an export, an import position is partner-allocated, so a hostile peer
/// could introduce unboundedly many distinct imports. `retain` therefore takes a
/// `max` and refuses a *new* id past it (ADR-0025), so the cap is enforced at the
/// one place a row is added rather than at each call site. An already-held id is
/// a refcount bump and never trips the cap, because it adds no row. There is no
/// `register`: imports are only ever retained.
pub const ImportTable = struct {
    slots: SlotTable = .empty,
    /// Optional identities attached to live import rows: the old Node routing
    /// token (ADR-0069) and the opaque Host capability id (ADR-0096). Both die
    /// with the import row, so partner reuse of one numeric position cannot
    /// revive either identity. One optional map preserves the one-word empty
    /// session cost while the two application representations overlap during
    /// migration; the map is bounded by the import table's own cap.
    identities: ?*IdentityMap = null,

    const Identity = struct {
        // Both namespaces reserve zero, so scalar sentinels avoid optional-u64
        // tags; the third word accounts claimed Host/wire retains.
        node_token: u64 = 0,
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
    /// Adding a new import row can hit the partner-import cap; everything else
    /// an import table does (decrement, lookup) shares `SlotTable`'s errors.
    pub const RetainError = std.mem.Allocator.Error || error{ImportCapExceeded};
    pub const empty: ImportTable = .{};

    pub fn deinit(self: *ImportTable, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        if (self.identities) |map| {
            map.deinit(allocator);
            allocator.destroy(map);
            self.identities = null;
        }
    }

    /// The node-unique token `position` was enrolled under, or null.
    pub fn tokenOf(self: *const ImportTable, position: Id) ?u64 {
        const map = self.identities orelse return null;
        const token = (map.get(position.int()) orelse return null).node_token;
        return if (token == 0) null else token;
    }

    /// Record the token `position` was enrolled under. A row that is not held
    /// records nothing: a token outliving its row is the staleness this table
    /// keeps the tokens to avoid, so the caller mints a fresh one next time
    /// rather than reading one back for a capability that is gone.
    pub fn noteToken(self: *ImportTable, allocator: std.mem.Allocator, position: Id, token: u64) !void {
        if (!self.slots.contains(position.int())) return;
        const map = try self.identityMap(allocator);
        const gop = try map.getOrPut(allocator, position.int());
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.node_token = token;
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

    /// Attach `host_ref` to this live import. A vanished row fails loudly rather
    /// than returning a Host handle with no lifecycle authority behind it.
    pub fn noteHostRef(self: *ImportTable, allocator: std.mem.Allocator, position: Id, host_ref: u64) !void {
        if (!self.slots.contains(position.int())) return error.UnknownImport;
        const map = try self.identityMap(allocator);
        const gop = try map.getOrPut(allocator, position.int());
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.host_ref = host_ref;
        gop.value_ptr.lifted_retains = 1;
    }

    /// Claim one more wire retain for an already-canonical Host identity.
    pub fn claimHostRetain(self: *ImportTable, position: Id, host_ref: u64) !void {
        const map = self.identities orelse return error.UnknownImport;
        const identity = map.getPtr(position.int()) orelse return error.UnknownImport;
        if (identity.host_ref != host_ref) return error.UnknownImport;
        if (identity.lifted_retains >= self.slots.count(position.int())) return error.NoUnliftedImportRetain;
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
    /// A Node token sharing the row remains intact.
    pub fn forgetHostRef(self: *ImportTable, position: Id, host_ref: u64) void {
        const map = self.identities orelse return;
        const identity = map.getPtr(position.int()) orelse return;
        if (identity.host_ref != host_ref) return;
        identity.host_ref = 0;
        identity.lifted_retains = 0;
        if (identity.node_token == 0) std.debug.assert(map.remove(position.int()));
    }

    pub fn len(self: *const ImportTable) usize {
        return self.slots.len();
    }

    pub fn contains(self: *const ImportTable, position: Id) bool {
        return self.slots.contains(position.int());
    }

    pub fn count(self: *const ImportTable, position: Id) u64 {
        return self.slots.count(position.int());
    }

    pub fn slotOf(self: *const ImportTable, position: Id) ?Slot {
        return self.slots.cell(position.int());
    }

    /// Wire-held references to `position`. An import carries no local
    /// baseline — every reference is one the wire introduced — so this is
    /// exactly `count`; it exists so GC validation reads one name across
    /// both tables.
    pub fn wireHeld(self: *const ImportTable, position: Id) u64 {
        return self.slots.count(position.int());
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
        return self.slots.retain(allocator, position.int(), .{ .remote_value = position.int() });
    }

    pub fn decrement(self: *ImportTable, position: Id, delta: u64) SlotTable.Error!void {
        try self.slots.decrement(position.int(), delta);
        if (self.identities) |map| {
            // Tolerant: only an identity-bearing import has a memo to drop.
            if (!self.slots.contains(position.int()) and map.contains(position.int()))
                std.debug.assert(map.remove(position.int()));
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
