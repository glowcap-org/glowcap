//! The portable Store: bounded staging, checked phase transitions, and
//! resolution against adapter-reported outcomes. Backends execute the emitted
//! batch inside their own atomic transaction. This type owns no I/O.
const std = @import("std");
const records = @import("loam_records");
const transaction = @import("transaction.zig");
const residency = @import("residency.zig");
const collection = @import("collection.zig");
const retention = @import("retention.zig");
const custody = @import("collection_custody.zig");

pub const Store = struct {
    allocator: std.mem.Allocator,
    metadata: transaction.Metadata,
    cache: residency.Cache,
    retentions: retention.Registry,
    collection_work: ?collection.Request = null,
    collector: ?custody.Custody = null,
    changes: []transaction.Mutation,
    /// The decoded view of each staged change's bytes, indexed like `changes`,
    /// so composing onto a staged row reads it back without re-validating the
    /// envelope and its checksum on every lookup.
    staged_views: []records.View,
    count: usize = 0,
    staged_bytes: usize = 0,
    /// Advances with every transition of the phase, the ticket, the committed
    /// metadata, or the staged set, so a reader that checked itself against
    /// the store can tell that nothing it checked has moved, without reading
    /// any of it back. Every assignment to those fields advances it.
    state_generation: u64 = 0,
    limits: Limits,
    sequence: u64 = 0,
    object_sequence: u64 = 0,
    creation_floor: u64 = 0,
    retain_committed: bool = false,
    ticket: ?transaction.Ticket = null,
    phase: Phase = .idle,

    pub const Phase = enum { idle, staging, prepared, writing, uncertain };
    pub const Limits = struct {
        records: records.Limits = .{},
        cache_slots: usize = 64,
        /// Records a walk may start reading before it needs them. Each holds a
        /// cache slot and its record's bytes until demand pins it, so the
        /// slots and budget must cover demand plus this depth.
        read_ahead: usize = 8,
        max_leases: usize = 128,
        resident_bytes: usize = 4 * 1024 * 1024,
        max_changes: usize = 64,
        staging_bytes: usize = 4 * 1024 * 1024,
        max_retentions: usize = 128,
        max_collection_roots: usize = 4096,
    };

    /// Validate a Store configuration without opening or claiming a backend.
    pub fn validateConfiguration(schemas: []const records.Schema, limits: Limits) !void {
        if (limits.max_changes == 0 or schemas.len == 0) return error.InvalidLimits;
        for (schemas, 0..) |schema, i| {
            if (schema.version == 0) return error.UnsupportedSchema;
            for (schemas[0..i]) |prior| if (prior.id == schema.id and prior.version == schema.version) return error.DuplicateSchema;
        }
        try residency.Cache.validateLimits(limits.cache_slots, limits.max_leases, limits.resident_bytes, limits.records);
    }

    /// Schemas are borrowed until deinit. Metadata comes from an exclusively
    /// claimed backend, and the store continues the sequence that metadata
    /// last committed. Two live Stores over one claim are invalid.
    pub fn init(allocator: std.mem.Allocator, metadata: transaction.Metadata, schemas: []const records.Schema, limits: Limits) !Store {
        if (metadata.incarnation == 0) return error.InvalidLimits;
        try validateConfiguration(schemas, limits);
        var cache = try residency.Cache.init(allocator, limits.cache_slots, limits.read_ahead, limits.max_leases, limits.resident_bytes, limits.records, schemas);
        errdefer cache.deinit() catch unreachable;
        var retentions = try retention.Registry.init(allocator, limits.max_retentions);
        errdefer retentions.deinit(allocator) catch unreachable;
        const changes = try allocator.alloc(transaction.Mutation, limits.max_changes);
        errdefer allocator.free(changes);
        const staged_views = try allocator.alloc(records.View, limits.max_changes);
        return .{ .allocator = allocator, .metadata = metadata, .sequence = metadata.last_sequence, .cache = cache, .retentions = retentions, .changes = changes, .staged_views = staged_views, .limits = limits };
    }

    /// Refuses while a write, read completion, or lease still owns store memory.
    pub fn deinit(self: *Store) !void {
        if (self.phase != .idle) return error.Busy;
        for (self.retentions.entries) |entry| if (entry.sequence != 0) return error.Busy;
        try self.cache.deinit();
        try self.retentions.deinit(self.allocator);
        if (self.collector) |*work| work.deinit();
        self.allocator.free(self.changes);
        self.allocator.free(self.staged_views);
        self.* = undefined;
    }

    pub fn acquire(self: *Store, id: records.ObjectId) !residency.Acquisition {
        if (self.collection_work != null) return error.Busy;
        if (self.phase == .uncertain) return error.RecoveryRequired;
        return self.cache.acquire(self.metadata, id, self.collectionCustody());
    }

    /// Read-ahead is optional, so a store that refuses demand reads has no room.
    pub fn acquireAhead(self: *Store, id: records.ObjectId) !residency.Ahead {
        if (self.collection_work != null or self.phase == .uncertain) return .full;
        return self.cache.acquireAhead(self.metadata, id, self.collectionCustody());
    }

    pub fn completeRead(self: *Store, ticket: transaction.Ticket, result: residency.ReadResult) !void {
        if (self.phase == .uncertain) try self.cache.cancel(ticket);
        return self.cache.complete(self.metadata, ticket, result);
    }

    pub fn cancelRead(self: *Store, ticket: transaction.Ticket) !void {
        try self.cache.cancel(ticket);
    }

    /// The returned view borrows until release. It is a data snapshot, never
    /// evidence of current resource authority. Managed admission is separate.
    pub fn view(self: *Store, lease: residency.Lease) !records.View {
        if (self.phase == .uncertain) return error.RecoveryRequired;
        return self.cache.view(self.metadata, lease);
    }

    pub fn release(self: *Store, lease: residency.Lease) !void {
        try self.cache.release(self.metadata, lease);
    }

    /// Require a lease acquired at the current installed snapshot. Historical
    /// data remains viewable through view(), but cannot drive restoration.
    pub fn currentView(self: *Store, lease: residency.Lease) !records.View {
        if (self.phase == .uncertain) return error.RecoveryRequired;
        return self.cache.currentView(self.metadata, lease);
    }

    pub fn evict(self: *Store) void {
        self.cache.evict();
    }

    /// Acquire only already-resident current data. Never starts storage work.
    pub fn resident(self: *Store, id: records.ObjectId) !residency.Lease {
        if (self.collection_work != null) return error.Busy;
        if (self.phase == .uncertain) return error.RecoveryRequired;
        return self.cache.resident(self.metadata, id, self.collectionCustody());
    }

    pub fn evictObject(self: *Store, id: records.ObjectId) !bool {
        if (id.store != self.metadata.store) return error.ForeignObject;
        return self.cache.evictObject(id);
    }

    pub fn begin(self: *Store) !void {
        if (self.phase == .uncertain) return error.RecoveryRequired;
        if (self.phase != .idle) return error.Busy;
        if (self.metadata.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        self.sequence = try std.math.add(u64, self.sequence, 1);
        self.ticket = .{ .store = self.metadata.store, .incarnation = self.metadata.incarnation, .sequence = self.sequence, .revision = self.metadata.revision };
        self.creation_floor = self.object_sequence;
        self.phase = .staging;
        self.state_generation +%= 1;
    }

    /// Reserves an unpublished name for this opening, including forward edges
    /// and cycles within the current transaction. Names are never recycled.
    pub fn allocateId(self: *Store) !records.ObjectId {
        if (self.phase != .staging) return error.WrongPhase;
        self.object_sequence = try std.math.add(u64, self.object_sequence, 1);
        return .{ .store = self.metadata.store, .incarnation = self.metadata.incarnation, .sequence = self.object_sequence };
    }

    /// Copies a complete proposed record. A null expected revision creates a
    /// freshly allocated object. Otherwise the backend compares the existing row.
    /// Re-proposing a record this transaction already staged replaces the staged
    /// bytes and keeps the staged revision expectation, so one transaction can
    /// compose several operations that each advance the same record (an owner
    /// header, a parent row, a shared directory page) while the submitted batch
    /// still holds exactly one mutation per record. A different expectation, or
    /// re-proposing a staged removal, stays `DuplicateMutation`.
    pub fn putCopying(self: *Store, record: records.Record, expected: ?u64) !void {
        if (self.phase != .staging) return error.WrongPhase;
        if (record.id.store != self.metadata.store) return error.ForeignObject;
        if (self.stagedIndex(record.id)) |index| {
            const existing = self.changes[index];
            if (existing.bytes == null or !std.meta.eql(existing.expected, expected)) return error.DuplicateMutation;
            const old_len = existing.bytes.?.len;
            const bytes = try self.encodeProposed(record, old_len);
            errdefer self.allocator.free(bytes);
            if (bytes.len > self.limits.staging_bytes - self.staged_bytes + old_len) return error.StagingCapacity;
            const staged_view = try self.decodeStaged(bytes);
            self.allocator.free(existing.bytes.?);
            self.changes[index] = .{ .id = record.id, .expected = expected, .bytes = bytes };
            self.staged_views[index] = staged_view;
            self.staged_bytes = self.staged_bytes - old_len + bytes.len;
            self.state_generation +%= 1;
            return;
        }
        if (self.count == self.changes.len) return error.ChangeCapacity;
        if (expected == null and (record.id.incarnation != self.metadata.incarnation or record.id.sequence > self.object_sequence or record.id.sequence <= self.creation_floor)) return error.InvalidObject;
        const bytes = try self.encodeProposed(record, 0);
        errdefer self.allocator.free(bytes);
        if (bytes.len > self.limits.staging_bytes - self.staged_bytes) return error.StagingCapacity;
        self.staged_views[self.count] = try self.decodeStaged(bytes);
        self.changes[self.count] = .{ .id = record.id, .expected = expected, .bytes = bytes };
        self.count += 1;
        self.staged_bytes += bytes.len;
        self.state_generation +%= 1;
    }

    fn encodeProposed(self: *Store, record: records.Record, extra: usize) ![]u8 {
        var staged_record = record;
        staged_record.revision = self.metadata.revision + 1;
        var bounded = self.limits.records;
        bounded.max_record_bytes = @min(bounded.max_record_bytes, self.limits.staging_bytes - self.staged_bytes + extra);
        return staged_record.encodeAlloc(self.allocator, bounded, self.cache.schemas);
    }

    /// The encoder just produced `bytes`; decoding them once here is the
    /// envelope check every later read-back would otherwise repeat.
    fn decodeStaged(self: *Store, bytes: []const u8) !records.View {
        return records.View.decode(bytes, self.limits.records, self.cache.schemas);
    }

    fn stagedIndex(self: *Store, id: records.ObjectId) ?usize {
        for (self.changes[0..self.count], 0..) |change, i| if (change.id.eql(id)) return i;
        return null;
    }

    pub const Proposed = struct { view: records.View, expected: ?u64 };

    /// The transaction's own staged proposal for `id`, decoded for read-back, or
    /// null when this transaction staged none. Staging consults it to compose
    /// further changes onto the same record: each stage then re-proposes the
    /// record with the composed delta. The view borrows store-owned memory until
    /// that row is re-proposed or the transaction ends. The expectation is copied.
    pub fn proposed(self: *Store, id: records.ObjectId) !?Proposed {
        if (self.phase != .staging) return null;
        const index = self.stagedIndex(id) orelse return null;
        const change = self.changes[index];
        if (change.bytes == null) return null;
        return .{ .view = self.staged_views[index], .expected = change.expected };
    }

    pub fn remove(self: *Store, id: records.ObjectId, expected: u64) !void {
        try self.admit(id);
        self.changes[self.count] = .{ .id = id, .expected = expected, .bytes = null };
        self.count += 1;
        self.state_generation +%= 1;
    }

    pub fn prepare(self: *Store) !transaction.Ticket {
        if (self.phase != .staging or self.count == 0) return error.WrongPhase;
        self.phase = .prepared;
        self.state_generation +%= 1;
        return self.ticket.?;
    }

    /// Prefer retaining prepared record buffers as resident data after commit.
    /// Installation transfers ownership without allocation; pinned/cache-full
    /// cases may leave a record cold. This changes residency, not durability.
    pub fn retainOnCommit(self: *Store) !void {
        if (self.phase != .staging) return error.WrongPhase;
        self.retain_committed = true;
    }

    /// The immutable batch borrows store-owned memory until terminal completion.
    /// An adapter must stop accessing it before reporting any terminal outcome.
    pub fn beginWrite(self: *Store, ticket: transaction.Ticket) !transaction.Batch {
        try self.match(ticket, .prepared);
        self.phase = .writing;
        self.state_generation +%= 1;
        return self.batch();
    }

    pub fn completeWrite(self: *Store, ticket: transaction.Ticket, outcome: transaction.Outcome) !void {
        try self.match(ticket, .writing);
        switch (outcome) {
            .unknown => {
                self.phase = .uncertain;
                self.state_generation +%= 1;
            },
            .unchanged => self.discard(),
            .committed => |meta| try self.install(meta),
        }
    }

    pub fn recoveryBatch(self: *Store) !transaction.Batch {
        if (self.phase != .uncertain) return error.WrongPhase;
        return self.batch();
    }

    /// Recovery runs only after the original worker has terminated. A missing
    /// receipt cannot prove absence while that worker could still commit.
    pub fn resolve(self: *Store, ticket: transaction.Ticket, resolution: transaction.Resolution) !void {
        try self.match(ticket, .uncertain);
        switch (resolution) {
            .committed => |meta| try self.install(meta),
            .unchanged => self.discard(),
        }
    }

    pub fn abort(self: *Store) !void {
        if (self.phase != .staging and self.phase != .prepared) return error.Busy;
        self.discard();
    }

    fn admit(self: *Store, id: records.ObjectId) !void {
        if (self.phase != .staging) return error.WrongPhase;
        if (id.store != self.metadata.store) return error.ForeignObject;
        if (self.count == self.changes.len) return error.ChangeCapacity;
        for (self.changes[0..self.count]) |change| if (change.id.eql(id)) return error.DuplicateMutation;
    }

    fn match(self: *Store, ticket: transaction.Ticket, phase: Phase) !void {
        if (self.ticket == null or !std.meta.eql(self.ticket.?, ticket)) return error.StaleCompletion;
        if (self.phase != phase) return error.WrongPhase;
    }

    fn batch(self: *Store) transaction.Batch {
        return .{ .ticket = self.ticket.?, .changes = self.changes[0..self.count], .limits = self.limits.records, .schemas = self.cache.schemas, .collection = self.collection_work };
    }

    fn install(self: *Store, meta: transaction.Metadata) !void {
        self.phase = .uncertain;
        self.state_generation +%= 1;
        const resolution = try self.batch().resolve(meta);
        if (resolution != .committed) return error.RecoveryRequired;
        self.cache.install(self.metadata, meta, self.changes[0..self.count], self.collection_work != null);
        self.metadata = meta;
        if (self.collection_work) |work| {
            self.collector.?.acknowledge(work.roots.len);
            if (meta.collection.phase == .idle) {
                self.collector.?.deinit();
                self.collector = null;
            }
        }
        if (self.retain_committed) for (self.changes[0..self.count]) |*change| {
            if (change.bytes) |bytes| {
                if (self.cache.adoptCommitted(meta, change.id, bytes)) change.bytes = null;
            }
        };
        self.discard();
    }

    fn discard(self: *Store) void {
        self.collection_work = null;
        for (self.changes[0..self.count]) |change| if (change.bytes) |bytes| self.allocator.free(bytes);
        self.count = 0;
        self.staged_bytes = 0;
        self.state_generation +%= 1;
        self.ticket = null;
        self.retain_committed = false;
        self.phase = .idle;
    }

    /// Keep an object and its strong graph alive independently of residency.
    /// This is privileged local custody. Callers must still obtain remote
    /// authority through Host capabilities, never by presenting this token.
    pub fn retain(self: *Store, id: records.ObjectId) !retention.Retention {
        if (self.phase == .uncertain) return error.RecoveryRequired;
        if (self.collection_work != null) return error.Busy;
        const prepared = try self.retentions.prepare(self.metadata, id);
        if (self.collectionCustody()) |work| try work.reserve(1);
        const token = self.retentions.install(prepared);
        if (self.collectionCustody()) |work| work.append(id);
        return token;
    }

    pub fn releaseRetention(self: *Store, token: retention.Retention) !void {
        try self.retentions.release(self.metadata, token);
    }

    /// Prepare a bounded tracing batch. Execute and settle it through the
    /// ordinary beginWrite/completeWrite/recovery path. New leases and live
    /// retention claims wait until completion. Existing leases remain usable.
    /// A batch finishes the unit it started, so it can run two steps past `work_limit`.
    pub fn prepareCollection(self: *Store, work_limit: usize) !transaction.Ticket {
        if (work_limit == 0) return error.InvalidLimits;
        try self.begin();
        errdefer self.discard();
        if (self.collector == null) try self.captureCollectionCustody();
        const work = &self.collector.?;
        self.collection_work = .{
            .roots = if (self.metadata.collection.phase == .idle or self.metadata.collection.tracing()) work.roots.items else &.{},
            .work_limit = work_limit,
            .scratch = work.scratch,
        };
        self.phase = .prepared;
        self.state_generation +%= 1;
        return self.ticket.?;
    }

    fn captureCollectionCustody(self: *Store) !void {
        var work = try custody.Custody.init(self.allocator, self.limits.max_collection_roots, self.limits.records.max_record_bytes);
        errdefer work.deinit();
        for (self.retentions.entries) |entry| if (entry.sequence != 0) {
            try work.reserve(1);
            work.append(entry.id);
        };
        for (self.cache.slots) |*slot| {
            if (slot.id() == null or (slot.pins == 0 and slot.contents != .loading)) continue;
            if (slot.contents == .resident) {
                const portrait = slot.contents.resident.view;
                try work.reserveRecord(portrait);
                work.appendRecord(portrait);
            } else {
                try work.reserve(1);
                work.append(slot.id().?);
            }
        }
        // Publish tracking only after every holder fits. A failed capture leaves
        // all portraits unmodified, so retry cannot mistake them for shaded data.
        for (self.cache.slots) |*slot| if (slot.contents == .resident) {
            slot.contents.resident.collection_reported = slot.pins != 0;
        };
        self.collector = work;
    }

    fn collectionCustody(self: *Store) ?*custody.Custody {
        // Finishing cannot delete another record. Its surviving holders are
        // captured at the next cycle, so admission creates no mark obligation.
        if (self.metadata.collection.phase == .finishing) return null;
        if (self.collector) |*work| return work;
        return null;
    }
};
