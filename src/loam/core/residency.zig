//! Bounded record residency with checked leases and retained read completions.
//!
//! A demand read asks for one record at one revision. `index` maps each
//! record to the slot that holds it, and the rare second slot holding an
//! older pinned snapshot of the same record hangs off the first by `chain`,
//! so a hit costs one hash probe however many slots the store was given and
//! a commit, which only moves revisions, touches no key. The slot inventory
//! stays the authority for what is resident; the index changes only where
//! slot contents do, in `place` and `discard`.
const std = @import("std");
const identity_hash = @import("foundation").identity_hash;
const records = @import("loam_records");
const tx = @import("transaction.zig");
const custody = @import("collection_custody.zig");

/// `result` with a `RecordUnloaded` read as null: the Store evicted a record
/// this step depends on, and the caller's activation loop reacquires it on
/// its next turn. Every other error is the step's own.
pub fn reload(result: anytype) Reloaded(@TypeOf(result)) {
    return result catch |err| {
        if (err == error.RecordUnloaded) return null;
        return err;
    };
}

fn Reloaded(comptime Result: type) type {
    const info = @typeInfo(Result).error_union;
    return info.error_set!?info.payload;
}

pub const Lease = struct { store: records.StoreId, incarnation: u64, slot: usize, sequence: u64 };
pub const Read = struct { ticket: tx.Ticket, id: records.ObjectId, buffer: []u8 };
pub const ReadResult = union(enum) { found: struct { length: usize, metadata: tx.Metadata }, missing, failed: anyerror };
pub const Acquisition = union(enum) { ready: Lease, read: Read };
/// A read-ahead either starts a read, finds the record already resident or
/// loading, or finds the cache holding its remaining room for demand.
pub const Ahead = union(enum) { read: Read, held, full };
/// Byte custody has three exclusive states. A completed buffer and its checked
/// envelope live together until eviction. Pending work cannot expose a view.
/// The fixed slot inventory owns descriptors, so view access allocates and
/// copies no record bytes and never repeats checksum or edge validation. A resident
/// snapshot may advance independently of the record and its historical leases.
const Slot = struct {
    contents: Contents = .empty,
    pins: usize = 0,
    used: u64 = 0,
    /// The next slot holding the same record at another revision.
    chain: u32 = no_slot,

    const Contents = union(enum) {
        empty,
        /// `ahead` marks a read-ahead load: demand that finds no room waits
        /// for it to land instead of refusing.
        loading: struct { bytes: []u8, id: records.ObjectId, ticket: tx.Ticket, canceled: bool = false, ahead: bool = false },
        resident: struct {
            bytes: []u8,
            view: records.View,
            snapshot: u64,
            // This exact immutable portrait, including historical edges, has
            // reported its collector obligations for the current local cycle.
            collection_reported: bool = false,
            /// Landed by read-ahead and not yet pinned. While its snapshot is
            /// current it counts against the read-ahead window, so read-ahead
            /// cannot outrun its consumer and evict what it loaded before
            /// demand arrives. A stale one is ordinary free room.
            ahead: bool = false,
        },
    };

    pub fn holds(self: *const Slot, object: records.ObjectId) bool {
        return if (self.id()) |own| own.eql(object) else false;
    }

    pub fn id(self: *const Slot) ?records.ObjectId {
        return switch (self.contents) {
            .empty => null,
            .loading => |value| value.id,
            .resident => |value| value.view.id,
        };
    }

    pub fn bytes(self: *const Slot) ?[]u8 {
        return switch (self.contents) {
            .empty => null,
            .loading => |value| value.bytes,
            .resident => |value| value.bytes,
        };
    }

    fn revision(self: *const Slot) ?u64 {
        return switch (self.contents) {
            .empty => null,
            .loading => |value| value.ticket.revision,
            .resident => |value| value.snapshot,
        };
    }
};
const Pin = struct { sequence: u64 = 0, slot: usize = 0, revision: u64 = 0 };
const no_slot = std.math.maxInt(u32);

pub const Cache = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    pins: []Pin,
    /// The newest-placed slot holding each record; its `chain` reaches any
    /// older snapshot still resident. Sized to the slot count at `init`, so
    /// no later operation allocates for it.
    index: identity_hash.ArrayMap(records.ObjectId, u32),
    limits: records.Limits,
    schemas: []const records.Schema,
    next: u64 = 0,
    allocated_bytes: usize = 0,
    budget: usize,
    read_ahead: usize,

    pub fn validateLimits(slots: usize, leases: usize, budget: usize, limits: records.Limits) !void {
        if (slots == 0 or leases == 0 or limits.max_record_bytes < 128 or budget < limits.max_record_bytes or limits.max_edges > records.Limits.max_edges_bound) return error.InvalidLimits;
    }

    pub fn init(allocator: std.mem.Allocator, slots: usize, read_ahead: usize, leases: usize, budget: usize, limits: records.Limits, schemas: []const records.Schema) !Cache {
        try validateLimits(slots, leases, budget, limits);
        const slot_count = std.math.cast(u32, slots) orelse return error.InvalidLimits;
        const entries = try allocator.alloc(Slot, slots);
        errdefer allocator.free(entries);
        const pins = try allocator.alloc(Pin, leases);
        errdefer allocator.free(pins);
        var index: identity_hash.ArrayMap(records.ObjectId, u32) = .{};
        errdefer index.deinit(allocator);
        try index.ensureTotalCapacity(allocator, slot_count);
        @memset(entries, .{});
        @memset(pins, .{});
        return .{ .allocator = allocator, .slots = entries, .pins = pins, .index = index, .limits = limits, .schemas = schemas, .budget = budget, .read_ahead = read_ahead };
    }

    pub fn deinit(self: *Cache) !void {
        for (self.slots) |*slot| if (slot.pins != 0 or slot.contents == .loading) return error.Busy;
        self.evict();
        std.debug.assert(self.index.count() == 0);
        self.index.deinit(self.allocator);
        self.allocator.free(self.slots);
        self.allocator.free(self.pins);
        self.* = undefined;
    }

    pub fn evict(self: *Cache) void {
        for (self.slots) |*slot| if (slot.pins == 0 and slot.contents != .loading) self.discard(slot);
    }

    pub fn resident(self: *Cache, meta: tx.Metadata, id: records.ObjectId, collector: ?*custody.Custody) !Lease {
        if (id.store != meta.store) return error.ForeignObject;
        const index = self.lookup(id, meta.revision) orelse return error.ResidencyRequired;
        if (self.slots[index].contents != .resident) return error.ResidencyRequired;
        return self.pin(meta, index, collector);
    }

    pub fn evictObject(self: *Cache, id: records.ObjectId) !bool {
        for (self.slots) |*slot| {
            if (slot.holds(id) and (slot.contents == .loading or slot.pins != 0)) return error.Busy;
        }
        var removed = false;
        for (self.slots) |*slot| {
            if (slot.holds(id)) {
                self.discard(slot);
                removed = true;
            }
        }
        return removed;
    }

    /// Carry proven unchanged resident bytes into the installed revision.
    /// Leases keep their acquisition revision. Pending reads still complete
    /// against their original snapshot. A sweep with deletions has no explicit
    /// mutation list, so it conservatively leaves every cached slot stale.
    pub fn install(self: *Cache, previous: tx.Metadata, current: tx.Metadata, changes: []const tx.Mutation, collecting: bool) void {
        if (collecting and previous.objects != current.objects) return;
        for (self.slots) |*slot| {
            if (slot.contents != .resident or slot.contents.resident.snapshot != previous.revision) continue;
            const id = slot.contents.resident.view.id;
            const changed = for (changes) |change| {
                if (change.id.eql(id)) break true;
            } else false;
            if (!changed) slot.contents.resident.snapshot = current.revision;
        }
    }

    /// Takes an already-validated prepared buffer only when existing capacity
    /// can hold it. No allocation, and no pinned snapshot is replaced.
    pub fn adoptCommitted(self: *Cache, meta: tx.Metadata, id: records.ObjectId, bytes: []u8) bool {
        if (bytes.len > self.budget) return false;
        var victim: ?usize = null;
        for (self.slots, 0..) |*slot, index| {
            if (slot.pins != 0 or slot.contents == .loading) continue;
            if (slot.holds(id)) {
                victim = index;
                break;
            }
            if (victim == null) {
                victim = index;
                continue;
            }
            const prior = &self.slots[victim.?];
            const stale = slot.bytes() == null or slot.revision() != meta.revision;
            const prior_stale = prior.contents == .empty or prior.revision() != meta.revision;
            if ((stale and !prior_stale) or (stale == prior_stale and slot.used < prior.used)) victim = index;
        }
        const index = victim orelse return false;
        const slot = &self.slots[index];
        const used = self.sequence() catch return false;
        self.discard(slot);
        while (self.allocated_bytes > self.budget - bytes.len) {
            if (!self.reclaimOldest(meta.revision, false)) return false;
        }
        // The immutable proposal was validated before storage submission. Establish
        // its checked envelope once when the buffer enters resident custody.
        const view_value = records.View.decode(bytes, self.limits, self.schemas) catch unreachable;
        std.debug.assert(view_value.id.eql(id) and view_value.revision == meta.revision);
        self.place(index, .{ .resident = .{ .bytes = bytes, .view = view_value, .snapshot = meta.revision } }, used);
        self.allocated_bytes += bytes.len;
        return true;
    }

    pub fn acquire(self: *Cache, meta: tx.Metadata, id: records.ObjectId, collector: ?*custody.Custody) !Acquisition {
        if (id.store != meta.store) return error.ForeignObject;
        if (self.lookup(id, meta.revision)) |index| {
            if (self.slots[index].contents == .loading) return error.PendingRead;
            return .{ .ready = try self.pin(meta, index, collector) };
        }
        return .{ .read = try self.load(meta, id, collector, false) };
    }

    /// Start a read for a record the caller expects to need soon. Read-ahead,
    /// loading or landed but unpinned, holds at most `read_ahead` slots and
    /// never the last slot or the last largest record of byte budget that
    /// pins and demand loads leave. A demand acquire that finds no room waits for a read-ahead to
    /// land, so read-ahead never makes demand refuse.
    pub fn acquireAhead(self: *Cache, meta: tx.Metadata, id: records.ObjectId, collector: ?*custody.Custody) !Ahead {
        if (id.store != meta.store) return error.ForeignObject;
        if (self.lookup(id, meta.revision) != null) return .held;
        var held: usize = 0;
        var held_bytes: usize = 0;
        var ahead: usize = 0;
        for (self.slots) |*slot| {
            const read_ahead = aheadOf(slot, meta.revision);
            if (read_ahead) ahead += 1;
            if (read_ahead or slot.pins != 0 or slot.contents == .loading) {
                held += 1;
                held_bytes += slot.bytes().?.len;
            }
        }
        if (ahead >= self.read_ahead or held + 2 > self.slots.len) return .full;
        if (held_bytes + 2 * self.limits.max_record_bytes > self.budget) return .full;
        return .{ .read = try self.load(meta, id, collector, true) };
    }

    /// Take a free slot for a new read of `id`: an empty one first, then the
    /// least recently used record no one waits on. Demand takes a landed
    /// read-ahead only when nothing else is free. Read-ahead never does.
    fn load(self: *Cache, meta: tx.Metadata, id: records.ObjectId, collector: ?*custody.Custody, ahead: bool) !Read {
        var victim: ?usize = null;
        for (self.slots, 0..) |*slot, i| {
            if (slot.pins != 0 or slot.contents == .loading or (ahead and aheadOf(slot, meta.revision))) continue;
            if (victim == null or before(slot, &self.slots[victim.?], meta.revision)) victim = i;
            if (slot.bytes() == null) break;
        }
        const index = victim orelse return self.noRoom();
        if (collector) |work| try work.reserve(1);
        const read_sequence = try self.sequence();
        const slot = &self.slots[index];
        self.discard(slot);
        while (self.allocated_bytes > self.budget - self.limits.max_record_bytes) {
            if (!self.reclaimOldest(meta.revision, ahead)) return self.noRoom();
        }
        const bytes = try self.allocator.alloc(u8, self.limits.max_record_bytes);
        self.allocated_bytes += bytes.len;
        const ticket: tx.Ticket = .{ .store = meta.store, .incarnation = meta.incarnation, .sequence = read_sequence, .revision = meta.revision };
        self.place(index, .{ .loading = .{ .bytes = bytes, .id = id, .ticket = ticket, .ahead = ahead } }, read_sequence);
        if (collector) |work| work.append(id);
        return .{ .ticket = ticket, .id = id, .buffer = bytes };
    }

    /// A read-ahead in flight will free room when it lands, so demand waits
    /// for it as for any pending read. Otherwise the cache is truly full.
    fn noRoom(self: *const Cache) error{ PendingRead, ResidentCapacity } {
        for (self.slots) |*slot| {
            if (slot.contents == .loading and slot.contents.loading.ahead) return error.PendingRead;
        }
        return error.ResidentCapacity;
    }

    /// Retires the read's buffer only after its adapter has completed. A canceled
    /// request keeps ownership until this method receives that completion.
    pub fn complete(self: *Cache, current: tx.Metadata, ticket: tx.Ticket, result: ReadResult) !void {
        const slot = try self.loading(ticket);
        errdefer self.discard(slot);
        if (slot.contents.loading.canceled) return error.Canceled;
        if (current.store != ticket.store or current.incarnation != ticket.incarnation or current.revision != ticket.revision) return error.StaleCompletion;
        switch (result) {
            .missing => return error.Gone,
            .failed => |err| return err,
            .found => |found| {
                if (found.metadata.store != current.store or found.metadata.incarnation != current.incarnation or found.metadata.revision != ticket.revision) return error.StaleCompletion;
                const pending = slot.contents.loading;
                if (found.length > pending.bytes.len) return error.RecordTooLarge;
                // The read reserved a maximum-size buffer before the length was
                // known. A copy of only the record's bytes lets the cache charge
                // what it holds, so the byte budget counts records at their
                // real size. The copy briefly holds one record beyond the
                // budget. Without memory for it the read fails like any other
                // refused load and leaves nothing resident.
                const exact = try self.allocator.dupe(u8, pending.bytes[0..found.length]);
                errdefer self.allocator.free(exact);
                const decoded = try records.View.decode(exact, self.limits, self.schemas);
                if (!decoded.id.eql(pending.id) or decoded.revision > ticket.revision) return error.Corrupt;
                self.allocated_bytes -= pending.bytes.len - exact.len;
                self.allocator.free(pending.bytes);
                slot.contents = .{ .resident = .{ .bytes = exact, .view = decoded, .snapshot = ticket.revision, .ahead = pending.ahead } };
            },
        }
    }

    pub fn cancel(self: *Cache, ticket: tx.Ticket) !void {
        (try self.loading(ticket)).contents.loading.canceled = true;
    }

    pub fn view(self: *Cache, metadata: tx.Metadata, lease: Lease) !records.View {
        const pin_entry = try self.checkedPin(metadata, lease);
        const slot = &self.slots[pin_entry.slot];
        return slot.contents.resident.view;
    }

    pub fn currentView(self: *Cache, metadata: tx.Metadata, lease: Lease) !records.View {
        const pin_entry = try self.checkedPin(metadata, lease);
        if (pin_entry.revision != metadata.revision) return error.StaleSnapshot;
        return self.slots[pin_entry.slot].contents.resident.view;
    }

    pub fn release(self: *Cache, metadata: tx.Metadata, lease: Lease) !void {
        const pin_entry = try self.checkedPin(metadata, lease);
        self.slots[pin_entry.slot].pins -= 1;
        pin_entry.sequence = 0;
    }

    fn checkedPin(self: *Cache, metadata: tx.Metadata, lease: Lease) !*Pin {
        if (lease.store != metadata.store or lease.incarnation != metadata.incarnation or lease.slot >= self.pins.len or lease.sequence == 0) return error.InvalidLease;
        const pin_entry = &self.pins[lease.slot];
        if (pin_entry.sequence != lease.sequence) return error.InvalidLease;
        return pin_entry;
    }

    fn pin(self: *Cache, metadata: tx.Metadata, index: usize, collector: ?*custody.Custody) !Lease {
        std.debug.assert(self.slots[index].contents == .resident);
        for (self.pins, 0..) |*entry, i| {
            if (entry.sequence != 0) continue;
            const portrait = &self.slots[index].contents.resident;
            if (collector) |work| if (!portrait.collection_reported) try work.reserveRecord(portrait.view);
            const seq = try self.sequence();
            entry.* = .{ .sequence = seq, .slot = index, .revision = metadata.revision };
            self.slots[index].pins += 1;
            self.slots[index].used = seq;
            portrait.ahead = false;
            if (collector) |work| if (!portrait.collection_reported) {
                work.appendRecord(portrait.view);
                portrait.collection_reported = true;
            };
            return .{ .store = metadata.store, .incarnation = metadata.incarnation, .slot = i, .sequence = seq };
        }
        return error.LeaseCapacity;
    }

    fn sequence(self: *Cache) !u64 {
        self.next = try std.math.add(u64, self.next, 1);
        return self.next;
    }

    fn loading(self: *Cache, ticket: tx.Ticket) !*Slot {
        for (self.slots) |*slot| if (slot.contents == .loading) {
            if (std.meta.eql(slot.contents.loading.ticket, ticket)) return slot;
        };
        return error.StaleCompletion;
    }

    /// Discard the unpinned resident record `load` would take first. With
    /// `spare_ahead`, a current landed read-ahead stays.
    fn reclaimOldest(self: *Cache, revision: u64, spare_ahead: bool) bool {
        var oldest: ?*Slot = null;
        for (self.slots) |*slot| {
            if (slot.contents != .resident or slot.pins != 0 or (spare_ahead and aheadOf(slot, revision))) continue;
            if (oldest == null or before(slot, oldest.?, revision)) oldest = slot;
        }
        self.discard(oldest orelse return false);
        return true;
    }

    /// Eviction order among unpinned slots: empty, then records no one waits
    /// on, then landed read-ahead, each least recently used first.
    fn before(slot: *const Slot, other: *const Slot, revision: u64) bool {
        if ((slot.bytes() == null) != (other.bytes() == null)) return slot.bytes() == null;
        if (aheadOf(slot, revision) != aheadOf(other, revision)) return !aheadOf(slot, revision);
        return slot.used < other.used;
    }

    /// A read-ahead in flight, or landed at `revision` where demand can
    /// still pin it.
    fn aheadOf(slot: *const Slot, revision: u64) bool {
        return switch (slot.contents) {
            .empty => false,
            .loading => |value| value.ahead,
            .resident => |value| value.ahead and value.snapshot == revision,
        };
    }

    /// The slot holding `id` at `revision`, loading or resident.
    fn lookup(self: *const Cache, id: records.ObjectId, revision: u64) ?u32 {
        var index = self.index.get(id) orelse return null;
        while (index != no_slot) : (index = self.slots[index].chain) {
            if (self.slots[index].revision().? == revision) return index;
        }
        return null;
    }

    /// Fill an empty slot and index what it now holds, ahead of any older
    /// snapshot of the same record.
    fn place(self: *Cache, index: usize, contents: Slot.Contents, used: u64) void {
        const slot = &self.slots[index];
        std.debug.assert(slot.contents == .empty);
        slot.* = .{ .contents = contents, .used = used };
        const head = self.index.getOrPutAssumeCapacity(slot.id().?);
        slot.chain = if (head.found_existing) head.value_ptr.* else no_slot;
        head.value_ptr.* = @intCast(index);
    }

    /// Take `slot` out of its record's chain, dropping the record's key with
    /// its last slot.
    fn unlink(self: *Cache, slot: *Slot) void {
        const id = slot.id() orelse return;
        const me: u32 = @intCast((@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot));
        const head = self.index.getPtr(id).?;
        if (head.* == me) {
            if (slot.chain == no_slot) {
                std.debug.assert(self.index.swapRemove(id));
            } else head.* = slot.chain;
            return;
        }
        var prev = &self.slots[head.*];
        while (prev.chain != me) prev = &self.slots[prev.chain];
        prev.chain = slot.chain;
    }

    fn discard(self: *Cache, slot: *Slot) void {
        self.unlink(slot);
        if (slot.bytes()) |bytes| {
            self.allocated_bytes -= bytes.len;
            self.allocator.free(bytes);
        }
        slot.* = .{};
    }
};
