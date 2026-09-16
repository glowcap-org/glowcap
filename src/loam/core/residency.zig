//! Bounded record residency with checked leases and retained read completions.
const std = @import("std");
const records = @import("loam_records");
const tx = @import("transaction.zig");
pub const Lease = struct { store: records.StoreId, incarnation: u64, slot: usize, sequence: u64 };
pub const Read = struct { ticket: tx.Ticket, id: records.ObjectId, buffer: []u8 };
pub const ReadResult = union(enum) { found: struct { length: usize, metadata: tx.Metadata }, missing, failed: anyerror };
pub const Acquisition = union(enum) { ready: Lease, read: Read };
const Slot = struct {
    bytes: ?[]u8 = null,
    length: usize = 0,
    id: ?records.ObjectId = null,
    revision: u64 = 0,
    loading: ?tx.Ticket = null,
    canceled: bool = false,
    pins: usize = 0,
    used: u64 = 0,
};
const Pin = struct { sequence: u64 = 0, slot: usize = 0, revision: u64 = 0 };
pub const Cache = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    pins: []Pin,
    limits: records.Limits,
    schemas: []const records.Schema,
    next: u64 = 0,
    allocated_bytes: usize = 0,
    budget: usize,

    pub fn init(allocator: std.mem.Allocator, slots: usize, leases: usize, budget: usize, limits: records.Limits, schemas: []const records.Schema) !Cache {
        if (slots == 0 or leases == 0 or limits.max_record_bytes < 128 or budget < limits.max_record_bytes) return error.InvalidLimits;
        const entries = try allocator.alloc(Slot, slots);
        errdefer allocator.free(entries);
        const pins = try allocator.alloc(Pin, leases);
        @memset(entries, .{});
        @memset(pins, .{});
        return .{ .allocator = allocator, .slots = entries, .pins = pins, .limits = limits, .schemas = schemas, .budget = budget };
    }

    pub fn deinit(self: *Cache) !void {
        for (self.slots) |slot| if (slot.pins != 0 or slot.loading != null) return error.Busy;
        self.evict();
        self.allocator.free(self.slots);
        self.allocator.free(self.pins);
        self.* = undefined;
    }

    pub fn evict(self: *Cache) void {
        for (self.slots) |*slot| if (slot.pins == 0 and slot.loading == null) self.discard(slot);
    }

    pub fn resident(self: *Cache, meta: tx.Metadata, id: records.ObjectId) !Lease {
        if (id.store != meta.store) return error.ForeignObject;
        for (self.slots, 0..) |slot, index| {
            if (slot.id != null and slot.id.?.eql(id) and slot.revision == meta.revision and slot.loading == null)
                return self.pin(meta, index);
        }
        return error.ResidencyRequired;
    }

    pub fn evictObject(self: *Cache, id: records.ObjectId) !bool {
        for (self.slots) |slot| {
            if (slot.id != null and slot.id.?.eql(id) and (slot.loading != null or slot.pins != 0)) return error.Busy;
        }
        var removed = false;
        for (self.slots) |*slot| {
            if (slot.id != null and slot.id.?.eql(id)) {
                self.discard(slot);
                removed = true;
            }
        }
        return removed;
    }

    /// Carry proven unchanged resident bytes into the installed revision.
    /// Leases keep their acquisition revision; pending reads still complete
    /// against their original snapshot. A sweep with deletions has no explicit
    /// mutation list, so it conservatively leaves every cached slot stale.
    pub fn install(self: *Cache, previous: tx.Metadata, current: tx.Metadata, changes: []const tx.Mutation, collecting: bool) void {
        if (collecting and previous.objects != current.objects) return;
        for (self.slots) |*slot| {
            if (slot.id == null or slot.loading != null or slot.revision != previous.revision) continue;
            const changed = for (changes) |change| {
                if (change.id.eql(slot.id.?)) break true;
            } else false;
            if (!changed) slot.revision = current.revision;
        }
    }

    /// Takes an already-validated prepared buffer only when existing capacity
    /// can hold it. No allocation, and no pinned snapshot is replaced.
    pub fn adoptCommitted(self: *Cache, meta: tx.Metadata, id: records.ObjectId, bytes: []u8) bool {
        if (bytes.len > self.budget) return false;
        var victim: ?usize = null;
        for (self.slots, 0..) |slot, index| {
            if (slot.pins != 0 or slot.loading != null) continue;
            if (slot.id != null and slot.id.?.eql(id)) {
                victim = index;
                break;
            }
            if (victim == null) {
                victim = index;
                continue;
            }
            const prior = self.slots[victim.?];
            const stale = slot.bytes == null or slot.revision != meta.revision;
            const prior_stale = prior.bytes == null or prior.revision != meta.revision;
            if ((stale and !prior_stale) or (stale == prior_stale and slot.used < prior.used)) victim = index;
        }
        const slot = &self.slots[victim orelse return false];
        const used = self.sequence() catch return false;
        self.discard(slot);
        while (self.allocated_bytes > self.budget - bytes.len) {
            var freed = false;
            for (self.slots) |*other| {
                if (other.bytes != null and other.pins == 0 and other.loading == null) {
                    self.discard(other);
                    freed = true;
                    break;
                }
            }
            if (!freed) return false;
        }
        slot.* = .{ .bytes = bytes, .length = bytes.len, .id = id, .revision = meta.revision, .used = used };
        self.allocated_bytes += bytes.len;
        return true;
    }

    pub fn acquire(self: *Cache, meta: tx.Metadata, id: records.ObjectId) !Acquisition {
        if (id.store != meta.store) return error.ForeignObject;
        for (self.slots, 0..) |*slot, i| {
            if (slot.id == null or !slot.id.?.eql(id) or slot.revision != meta.revision) continue;
            if (slot.loading != null) return error.PendingRead;
            return .{ .ready = try self.pin(meta, i) };
        }
        var victim: ?usize = null;
        for (self.slots, 0..) |slot, i| {
            if (slot.pins != 0 or slot.loading != null) continue;
            if (victim == null or slot.bytes == null or slot.used < self.slots[victim.?].used) victim = i;
            if (slot.bytes == null) break;
        }
        const index = victim orelse return error.ResidentCapacity;
        const read_sequence = try self.sequence();
        const slot = &self.slots[index];
        self.discard(slot);
        while (self.allocated_bytes > self.budget - self.limits.max_record_bytes) {
            var reclaimed = false;
            for (self.slots) |*other| {
                if (other.bytes != null and other.pins == 0 and other.loading == null) {
                    self.discard(other);
                    reclaimed = true;
                    break;
                }
            }
            if (!reclaimed) return error.ResidentCapacity;
        }
        const bytes = try self.allocator.alloc(u8, self.limits.max_record_bytes);
        self.allocated_bytes += bytes.len;
        const ticket: tx.Ticket = .{ .store = meta.store, .incarnation = meta.incarnation, .sequence = read_sequence, .revision = meta.revision };
        slot.* = .{ .bytes = bytes, .id = id, .revision = meta.revision, .loading = ticket, .used = read_sequence };
        return .{ .read = .{ .ticket = ticket, .id = id, .buffer = bytes } };
    }

    /// Retires the read's buffer only after its adapter has completed. A canceled
    /// request keeps ownership until this method receives that completion.
    pub fn complete(self: *Cache, current: tx.Metadata, ticket: tx.Ticket, result: ReadResult) !void {
        const slot = try self.loading(ticket);
        errdefer self.discard(slot);
        if (slot.canceled) return error.Canceled;
        if (current.store != ticket.store or current.incarnation != ticket.incarnation or current.revision != ticket.revision) return error.StaleCompletion;
        switch (result) {
            .missing => return error.Gone,
            .failed => |err| return err,
            .found => |found| {
                if (found.metadata.store != current.store or found.metadata.incarnation != current.incarnation or found.metadata.revision != ticket.revision) return error.StaleCompletion;
                if (found.length > slot.bytes.?.len) return error.RecordTooLarge;
                const decoded = try records.View.decode(slot.bytes.?[0..found.length], self.limits, self.schemas);
                if (!decoded.id.eql(slot.id.?) or decoded.revision > ticket.revision) return error.Corrupt;
                slot.length = found.length;
                slot.loading = null;
            },
        }
    }

    pub fn cancel(self: *Cache, ticket: tx.Ticket) !void {
        (try self.loading(ticket)).canceled = true;
    }

    pub fn view(self: *Cache, metadata: tx.Metadata, lease: Lease) !records.View {
        const pin_entry = try self.checkedPin(metadata, lease);
        const slot = self.slots[pin_entry.slot];
        return records.View.decode(slot.bytes.?[0..slot.length], self.limits, self.schemas);
    }

    pub fn currentView(self: *Cache, metadata: tx.Metadata, lease: Lease) !records.View {
        const pin_entry = try self.checkedPin(metadata, lease);
        if (pin_entry.revision != metadata.revision) return error.StaleSnapshot;
        return self.view(metadata, lease);
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

    fn pin(self: *Cache, metadata: tx.Metadata, index: usize) !Lease {
        for (self.pins, 0..) |*entry, i| {
            if (entry.sequence != 0) continue;
            const seq = try self.sequence();
            entry.* = .{ .sequence = seq, .slot = index, .revision = metadata.revision };
            self.slots[index].pins += 1;
            self.slots[index].used = seq;
            return .{ .store = metadata.store, .incarnation = metadata.incarnation, .slot = i, .sequence = seq };
        }
        return error.LeaseCapacity;
    }

    fn sequence(self: *Cache) !u64 {
        self.next = try std.math.add(u64, self.next, 1);
        return self.next;
    }

    fn loading(self: *Cache, ticket: tx.Ticket) !*Slot {
        for (self.slots) |*slot| if (slot.loading) |pending| {
            if (std.meta.eql(pending, ticket)) return slot;
        };
        return error.StaleCompletion;
    }

    fn discard(self: *Cache, slot: *Slot) void {
        if (slot.bytes) |bytes| {
            self.allocated_bytes -= bytes.len;
            self.allocator.free(bytes);
        }
        slot.* = .{};
    }
};
