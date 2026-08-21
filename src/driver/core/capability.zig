//! Host-scoped capability identity (ADR-0096).
//!
//! Wire positions remain session names. This registry gives the composed Host
//! an opaque name for the target behind one of those positions. Native refs
//! carry their Registry scope; adapters that erase it must provide a wider id
//! source.
//! A reverse index canonicalizes repeated observations, while an intrusive
//! per-session list invalidates exactly the rows homed on a closing session.
//! Invalidated rows keep only their id and outstanding application-retain
//! count: use fails immediately, but a later language-finalizer release still
//! has a deterministic recipient.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");

/// One Host-minted inline handoff promise. The containing Host is the owner
/// dimension; monotonic issuance is the epoch, and the distinct type keeps
/// this namespace out of every other Host integer table by construction.
pub const PromiseId = enum(u64) { _ };

/// An opaque capability in one Host composition. The registry pointer is the
/// scope proof. A pointer-free projection uses an adapter-injected process-wide
/// issuer so its raw handle also fails closed when presented to another Host.
/// `raw` exists only for the session memo and later ABI projection.
pub const Ref = struct {
    registry: *const Registry,
    id: CapabilityId,

    pub fn raw(self: Ref) u64 {
        return @backingInt(self.id);
    }

    pub fn eql(self: Ref, other: Ref) bool {
        return self.registry == other.registry and self.id == other.id;
    }
};
comptime {
    if (@sizeOf(Ref) != 16) @compileError("HostRef must remain a two-word scoped handle");
}

/// The target a Host capability retains while live.
pub const Target = union(enum) {
    /// One actor in the Host Vat. Ports lazily assign wire positions.
    local: u64,
    /// One real import on its owning session.
    remote: struct {
        peer_handle: engine.PeerHandle,
        far: model.FarRef,
        /// Host-monotonic stamp for this live import-row incarnation. A partner
        /// may reuse the numeric position after release; the stamp prevents the
        /// old Host row from becoming canonical for the replacement.
        incarnation: u64,
    },
    /// One Host-owned promise created before its handoff redemption settles.
    /// The promise row owns its eventual target; this registry owns only the
    /// opaque application identity and retain count.
    deferred: PromiseId,

    fn peerHandle(self: Target) ?engine.PeerHandle {
        return switch (self) {
            .local, .deferred => null,
            .remote => |remote| remote.peer_handle,
        };
    }

    fn key(self: Target) Key {
        return switch (self) {
            .local => |actor_id| .{ .local = actor_id },
            .remote => |remote| .{ .remote = .{
                .peer_handle = remote.peer_handle,
                .kind = remote.far.kind,
                .position = remote.far.import_position.int(),
                .incarnation = remote.incarnation,
            } },
            .deferred => |id| .{ .deferred = id },
        };
    }
};

const Key = union(enum) {
    local: u64,
    remote: struct {
        peer_handle: engine.PeerHandle,
        kind: model.RefKind,
        position: u64,
        incarnation: u64,
    },
    deferred: PromiseId,
};

const CapabilityId = enum(u64) { _ };

/// One fresh local identity minted before an actor becomes observable. This is
/// a short-lived transaction token: Host owns the reserve/commit sequence and
/// never stores it or lets another registry operation intervene.
pub const FreshLocalReservation = struct {
    registry: *Registry,
    id: CapabilityId,
};

/// Optional source for ids that leave the native scoped `Ref`. Native callers
/// need no issuer because the Registry pointer carries scope; pointer-free
/// adapters inject their own process-wide authority.
pub const IdIssuer = struct {
    ctx: ?*anyopaque = null,
    next: *const fn (?*anyopaque) error{CapabilitySpaceExhausted}!u64,
};

const Entry = struct {
    id: CapabilityId,
    target: Target,
    retains: u64,
    peer_prev: ?u32 = null,
    peer_next: ?u32 = null,
};

const RetiredEntry = struct {
    id: CapabilityId,
    retains: u64,
};

const Slot = struct {
    state: State,

    const State = union(enum) {
        free: ?u32,
        live: Entry,
        /// Its remote home has closed. No capability operation may resolve
        /// this row, but already-issued handles must still settle their
        /// release units without manufacturing UnknownCapability failures.
        retired: RetiredEntry,
    };
};

/// One live/reusable Host-capability slot. This is Host-wide, not per session;
/// keep the retained high-water cost explicit as the target grows fields.
pub const slot_budget_bytes: usize = 80;
comptime {
    if (@sizeOf(Slot) > slot_budget_bytes) @compileError(std.fmt.comptimePrint(
        "driver_core capability slot is {d} bytes, over its {d}-byte Host-wide retained-row budget",
        .{ @sizeOf(Slot), slot_budget_bytes },
    ));
}

/// Host-owned canonical capability rows. Storage grows to the high-water mark
/// of simultaneously live rows plus invalidated rows whose application retains
/// have not settled yet. Released slots are reused, but public ids are never
/// reused by this registry, so stale handles fail the Host-owned `by_id`
/// lookup. Pointer-free projections use opaque ids whose issuer also separates
/// Hosts; native refs carry the Registry pointer as their scope proof.
pub const Registry = struct {
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    free_head: ?u32 = null,
    by_target: std.AutoHashMapUnmanaged(Key, Ref) = .empty,
    by_id: std.AutoHashMapUnmanaged(CapabilityId, u32) = .empty,
    peer_heads: std.AutoHashMapUnmanaged(engine.PeerHandle, u32) = .empty,
    id_issuer: ?IdIssuer = null,
    next_local_id: u64 = ref_base,

    pub const Error = std.mem.Allocator.Error || error{
        CapabilitySpaceExhausted,
        RetainOverflow,
        ReleaseExceedsRetains,
        UnknownCapability,
    };

    // Private to this opaque type: this is not a reservation in any CapTP
    // position space. Keeping the high band makes zero and ordinary wire
    // positions invalid handles. `ref_end` is an exhausted sentinel and is
    // never issued.
    const ref_base: u64 = 1 << 62;
    const ref_end: u64 = 1 << 63;
    pub fn init(id_issuer: ?IdIssuer) Registry {
        return .{ .id_issuer = id_issuer };
    }

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        self.peer_heads.deinit(allocator);
        self.by_id.deinit(allocator);
        self.by_target.deinit(allocator);
        self.slots.deinit(allocator);
        self.* = .{};
    }

    /// Mint an id and reserve every backing slot a fresh local target needs.
    /// The Host calls this immediately before spawning or publishing an actor,
    /// then commits without any intervening registry operation. An id is
    /// deliberately burned when the later actor operation fails: public ids
    /// are never reused, including across rolled-back transactions.
    pub fn reserveFreshLocal(self: *Registry, allocator: std.mem.Allocator) Error!FreshLocalReservation {
        try self.by_target.ensureUnusedCapacity(allocator, 1);
        try self.by_id.ensureUnusedCapacity(allocator, 1);
        if (self.free_head == null) {
            if (self.slots.items.len > std.math.maxInt(u32)) return error.CapabilitySpaceExhausted;
            try self.slots.ensureUnusedCapacity(allocator, 1);
        }
        return .{ .registry = self, .id = try self.nextId() };
    }

    /// Commit the fresh local target promised by `reserveFreshLocal`. This is
    /// infallible because the reservation already minted the id and reserved
    /// both indexes and one slot. Actor ids are Vat-monotonic, so a freshly
    /// spawned actor cannot already have a live canonical row.
    pub fn commitFreshLocal(self: *Registry, reservation: FreshLocalReservation, actor_id: u64) Ref {
        std.debug.assert(reservation.registry == self);
        const target: Target = .{ .local = actor_id };
        std.debug.assert(!self.by_target.contains(target.key()));
        std.debug.assert(!self.by_id.contains(reservation.id));

        const acquired = self.acquireSlotAssumeCapacity();
        acquired.slot.state = .{ .live = .{
            .id = reservation.id,
            .target = target,
            .retains = 1,
        } };
        const ref = Ref{ .registry = self, .id = reservation.id };
        self.by_id.putAssumeCapacity(reservation.id, acquired.index);
        self.by_target.putAssumeCapacity(target.key(), ref);
        return ref;
    }

    /// Retain `target`, reusing its live Host identity when already observed.
    pub fn retain(self: *Registry, allocator: std.mem.Allocator, target: Target) Error!Ref {
        const key = target.key();
        if (self.by_target.get(key)) |existing| {
            const entry = self.entryPtr(existing) orelse unreachable;
            entry.retains = std.math.add(u64, entry.retains, 1) catch return error.RetainOverflow;
            return existing;
        }

        try self.by_target.ensureUnusedCapacity(allocator, 1);
        try self.by_id.ensureUnusedCapacity(allocator, 1);
        if (target.peerHandle()) |peer_handle| if (!self.peer_heads.contains(peer_handle))
            try self.peer_heads.ensureUnusedCapacity(allocator, 1);
        const id = try self.nextId();
        const acquired = try self.acquireSlot(allocator);
        const prior_head = if (target.peerHandle()) |peer_handle| self.peer_heads.get(peer_handle) else null;
        acquired.slot.state = .{ .live = .{
            .id = id,
            .target = target,
            .retains = 1,
            .peer_next = prior_head,
        } };
        if (target.peerHandle()) |peer_handle| {
            if (prior_head) |head| self.liveEntryAt(head).peer_prev = acquired.index;
            self.peer_heads.putAssumeCapacity(peer_handle, acquired.index);
        }
        const ref = Ref{ .registry = self, .id = id };
        self.by_id.putAssumeCapacity(id, acquired.index);
        self.by_target.putAssumeCapacity(key, ref);
        return ref;
    }

    /// Whether a canonical row for `target` already exists — the creation
    /// probe `Host` uses to pair an actor root with a fresh local slot
    /// (ADR-0101).
    pub fn hasTarget(self: *const Registry, target: Target) bool {
        return self.by_target.contains(target.key());
    }

    /// The still-live target behind `ref`, or null for a stale/foreign id.
    pub fn resolve(self: *const Registry, ref: Ref) ?Target {
        const slot_index = self.slotFor(ref) orelse return null;
        const slot = &self.slots.items[slot_index];
        return switch (slot.state) {
            .live => |entry| entry.target,
            else => null,
        };
    }

    /// Number of outstanding application retains on a usable or invalidated
    /// capability. Host release uses this to validate the whole delta before
    /// committing any corresponding wire GC.
    pub fn retainCount(self: *const Registry, ref: Ref) ?u64 {
        const slot_index = self.slotFor(ref) orelse return null;
        const slot = &self.slots.items[slot_index];
        return switch (slot.state) {
            .live => |entry| entry.retains,
            .retired => |entry| entry.retains,
            .free => null,
        };
    }

    /// Reconstitute this registry's scoped handle from an internally retained
    /// raw id. Invalidated rows remain nameable only so an already-issued
    /// application handle can release its outstanding unit; `resolve` still
    /// refuses every use. A fully released or foreign id stays stale.
    pub fn refForRaw(self: *const Registry, raw: u64) ?Ref {
        const id: CapabilityId = @fromBackingInt(@intCast(raw));
        if (!self.by_id.contains(id)) return null;
        return .{ .registry = self, .id = id };
    }

    /// Release `delta` application retains. The final release reclaims the row;
    /// its public id is never reused by this registry even when the slot is.
    pub fn release(self: *Registry, ref: Ref, delta: u64) Error!?Target {
        const slot_index = self.slotFor(ref) orelse return error.UnknownCapability;
        const slot = &self.slots.items[slot_index];
        switch (slot.state) {
            .free => return error.UnknownCapability,
            .live => |*entry| {
                if (delta == 0) return null;
                if (delta > entry.retains) return error.ReleaseExceedsRetains;
                entry.retains -= delta;
                if (entry.retains != 0) return null;
                return try self.remove(ref);
            },
            .retired => |*entry| {
                if (delta == 0) return null;
                if (delta > entry.retains) return error.ReleaseExceedsRetains;
                entry.retains -= delta;
                if (entry.retains != 0) return null;
                std.debug.assert(self.by_id.remove(entry.id));
                slot.state = .{ .free = self.free_head };
                self.free_head = slot_index;
                return null;
            },
        }
    }

    /// Invalidate every capability homed on `peer_handle` without scanning rows
    /// belonging to other sessions. The target and canonical index disappear
    /// immediately; a release-only row survives until every already-issued
    /// application retain settles. Returns the number invalidated.
    pub fn invalidatePeer(self: *Registry, peer_handle: engine.PeerHandle) usize {
        var count: usize = 0;
        while (self.peer_heads.get(peer_handle)) |slot_index| {
            const slot = &self.slots.items[slot_index];
            const entry = switch (slot.state) {
                .live => |entry| entry,
                .free, .retired => unreachable,
            };
            std.debug.assert(entry.target.peerHandle().? == peer_handle);
            std.debug.assert(entry.peer_prev == null);
            std.debug.assert(self.by_target.remove(entry.target.key()));
            if (entry.peer_next) |next| {
                self.liveEntryAt(next).peer_prev = null;
                self.peer_heads.putAssumeCapacity(peer_handle, next);
            } else {
                std.debug.assert(self.peer_heads.remove(peer_handle));
            }
            slot.state = .{ .retired = .{ .id = entry.id, .retains = entry.retains } };
            count += 1;
        }
        return count;
    }

    pub fn liveCount(self: *const Registry) usize {
        return self.by_target.count();
    }

    fn acquireSlot(self: *Registry, allocator: std.mem.Allocator) Error!struct { index: u32, slot: *Slot } {
        if (self.free_head) |index| {
            const slot = &self.slots.items[index];
            self.free_head = switch (slot.state) {
                .free => |next| next,
                else => unreachable,
            };
            return .{ .index = index, .slot = slot };
        }
        // `len` is the next index. The maximum u32 itself is still one valid
        // slot; only the following length is outside the encoded slot field.
        if (self.slots.items.len > std.math.maxInt(u32)) return error.CapabilitySpaceExhausted;
        const index: u32 = @intCast(self.slots.items.len);
        try self.slots.append(allocator, .{ .state = .{ .free = null } });
        return .{ .index = index, .slot = &self.slots.items[index] };
    }

    fn acquireSlotAssumeCapacity(self: *Registry) struct { index: u32, slot: *Slot } {
        if (self.free_head) |index| {
            const slot = &self.slots.items[index];
            self.free_head = switch (slot.state) {
                .free => |next| next,
                else => unreachable,
            };
            return .{ .index = index, .slot = slot };
        }
        std.debug.assert(self.slots.items.len <= std.math.maxInt(u32));
        const index: u32 = @intCast(self.slots.items.len);
        self.slots.appendAssumeCapacity(.{ .state = .{ .free = null } });
        return .{ .index = index, .slot = &self.slots.items[index] };
    }

    fn remove(self: *Registry, ref: Ref) Error!Target {
        const slot_index = self.slotFor(ref) orelse return error.UnknownCapability;
        const slot = &self.slots.items[slot_index];
        const entry = switch (slot.state) {
            .live => |entry| entry,
            else => return error.UnknownCapability,
        };

        std.debug.assert(self.by_target.remove(entry.target.key()));
        std.debug.assert(self.by_id.remove(entry.id));
        if (entry.target.peerHandle()) |peer_handle| {
            if (entry.peer_prev) |prev| {
                self.liveEntryAt(prev).peer_next = entry.peer_next;
            } else if (entry.peer_next) |next| {
                self.peer_heads.putAssumeCapacity(peer_handle, next);
            } else {
                std.debug.assert(self.peer_heads.remove(peer_handle));
            }
            if (entry.peer_next) |next| self.liveEntryAt(next).peer_prev = entry.peer_prev;
        }

        slot.state = .{ .free = self.free_head };
        self.free_head = slot_index;
        return entry.target;
    }

    fn entryPtr(self: *Registry, ref: Ref) ?*Entry {
        const slot_index = self.slotFor(ref) orelse return null;
        const slot = &self.slots.items[slot_index];
        return switch (slot.state) {
            .live => |*entry| entry,
            else => null,
        };
    }

    fn liveEntryAt(self: *Registry, index: u32) *Entry {
        return switch (self.slots.items[index].state) {
            .live => |*entry| entry,
            else => unreachable,
        };
    }

    pub fn refFromRaw(self: *const Registry, raw: u64) Ref {
        return .{ .registry = self, .id = @fromBackingInt(@intCast(raw)) };
    }

    fn slotFor(self: *const Registry, ref: Ref) ?u32 {
        if (ref.registry != self) return null;
        return self.by_id.get(ref.id);
    }

    fn nextId(self: *Registry) error{CapabilitySpaceExhausted}!CapabilityId {
        if (self.id_issuer) |issuer| {
            var attempts: u8 = 0;
            while (attempts < 16) : (attempts += 1) {
                const raw = try issuer.next(issuer.ctx);
                if (raw == 0) continue;
                const id: CapabilityId = @fromBackingInt(@intCast(raw));
                // A truncated opaque token may collide; retry before
                // publication instead of replacing live authority. The bound
                // also keeps a broken custom issuer from hanging the Host.
                if (!self.by_id.contains(id)) return id;
            }
            return error.CapabilitySpaceExhausted;
        }
        const raw = local: {
            if (self.next_local_id == ref_end) return error.CapabilitySpaceExhausted;
            const current = self.next_local_id;
            self.next_local_id += 1;
            break :local current;
        };
        if (raw == 0) return error.CapabilitySpaceExhausted;
        return @fromBackingInt(@intCast(raw));
    }
};
