//! Portable record transactions and bounded residency. Stores emit explicit
//! read and write work; the embedding owns execution and completion delivery.
const std = @import("std");
const records = @import("loam_records");
const transaction = @import("transaction.zig");
const residency = @import("residency.zig");
const collection = @import("collection.zig");
const retention = @import("retention.zig");
pub const Record = records.Record;
pub const RecordView = records.View;
pub const Edge = records.Edge;
pub const ObjectId = records.ObjectId;
pub const StoreId = records.StoreId;
pub const Schema = records.Schema;
pub const RecordLimits = records.Limits;
pub const Metadata = transaction.Metadata;
pub const Ticket = transaction.Ticket;
pub const Batch = transaction.Batch;
pub const Mutation = transaction.Mutation;
pub const Outcome = transaction.Outcome;
pub const Resolution = transaction.Resolution;
pub const Read = residency.Read;
pub const ReadResult = residency.ReadResult;
pub const Lease = residency.Lease;
pub const Acquisition = residency.Acquisition;
pub const metadata_key = transaction.metadata_key;
pub const CollectionProgress = collection.Progress;
pub const CollectionRow = collection.Row;
pub const Retention = retention.Retention;

pub const Store = struct {
    allocator: std.mem.Allocator,
    metadata: Metadata,
    cache: residency.Cache,
    retentions: retention.Registry,
    collection_work: ?collection.Request = null,
    changes: []Mutation,
    count: usize = 0,
    staged_bytes: usize = 0,
    limits: Limits,
    sequence: u64 = 0,
    object_sequence: u64 = 0,
    creation_floor: u64 = 0,
    retain_committed: bool = false,
    ticket: ?Ticket = null,
    digest: [32]u8 = @splat(0),
    phase: enum { idle, staging, prepared, writing, uncertain } = .idle,

    pub const Limits = struct {
        records: RecordLimits = .{},
        cache_slots: usize = 64,
        max_leases: usize = 128,
        resident_bytes: usize = 4 * 1024 * 1024,
        max_changes: usize = 64,
        staging_bytes: usize = 4 * 1024 * 1024,
        max_retentions: usize = 128,
        max_collection_roots: usize = 4096,
    };

    /// Schemas are borrowed until deinit. Metadata comes from an exclusively
    /// claimed backend; constructing another Store with the same claim is invalid.
    pub fn init(allocator: std.mem.Allocator, metadata: Metadata, schemas: []const Schema, limits: Limits) !Store {
        if (metadata.incarnation == 0 or limits.max_changes == 0 or schemas.len == 0) return error.InvalidLimits;
        for (schemas, 0..) |schema, i| {
            if (schema.version == 0) return error.UnsupportedSchema;
            for (schemas[0..i]) |prior| if (prior.id == schema.id and prior.version == schema.version) return error.DuplicateSchema;
        }
        var cache = try residency.Cache.init(allocator, limits.cache_slots, limits.max_leases, limits.resident_bytes, limits.records, schemas);
        errdefer cache.deinit() catch unreachable;
        var retentions = try retention.Registry.init(allocator, limits.max_retentions);
        errdefer retentions.deinit(allocator) catch unreachable;
        const changes = try allocator.alloc(Mutation, limits.max_changes);
        return .{ .allocator = allocator, .metadata = metadata, .cache = cache, .retentions = retentions, .changes = changes, .limits = limits };
    }

    /// Refuses while a write, read completion, or lease still owns store memory.
    pub fn deinit(self: *Store) !void {
        if (self.phase != .idle) return error.Busy;
        for (self.retentions.entries) |entry| if (entry.sequence != 0) return error.Busy;
        try self.cache.deinit();
        try self.retentions.deinit(self.allocator);
        self.allocator.free(self.changes);
        self.* = undefined;
    }

    pub fn acquire(self: *Store, id: ObjectId) !Acquisition {
        if (self.collection_work != null) return error.Busy;
        if (self.phase == .uncertain) return error.RecoveryRequired;
        return self.cache.acquire(self.metadata, id);
    }

    pub fn completeRead(self: *Store, ticket: Ticket, result: ReadResult) !void {
        if (self.phase == .uncertain) {
            try self.cache.cancel(ticket);
            return self.cache.complete(self.metadata, ticket, result);
        }
        return self.cache.complete(self.metadata, ticket, result);
    }

    pub fn cancelRead(self: *Store, ticket: Ticket) !void {
        try self.cache.cancel(ticket);
    }

    /// The returned view borrows until release. It is a data snapshot, never
    /// evidence of current resource authority. Managed admission is separate.
    pub fn view(self: *Store, lease: Lease) !RecordView {
        if (self.phase == .uncertain) return error.RecoveryRequired;
        return self.cache.view(self.metadata, lease);
    }

    pub fn release(self: *Store, lease: Lease) !void {
        try self.cache.release(self.metadata, lease);
    }

    /// Require a lease acquired at the current installed snapshot. Historical
    /// data remains viewable through view(), but cannot drive restoration.
    pub fn currentView(self: *Store, lease: Lease) !RecordView {
        if (self.phase == .uncertain) return error.RecoveryRequired;
        return self.cache.currentView(self.metadata, lease);
    }

    pub fn evict(self: *Store) void {
        self.cache.evict();
    }

    /// Acquire only already-resident current data; never starts storage work.
    pub fn resident(self: *Store, id: ObjectId) !Lease {
        if (self.collection_work != null) return error.Busy;
        if (self.phase == .uncertain) return error.RecoveryRequired;
        return self.cache.resident(self.metadata, id);
    }

    pub fn evictObject(self: *Store, id: ObjectId) !bool {
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
    }

    /// Reserves an unpublished name for this opening, including forward edges
    /// and cycles within the current transaction. Names are never recycled.
    pub fn allocateId(self: *Store) !ObjectId {
        if (self.phase != .staging) return error.WrongPhase;
        self.object_sequence = try std.math.add(u64, self.object_sequence, 1);
        return .{ .store = self.metadata.store, .incarnation = self.metadata.incarnation, .sequence = self.object_sequence };
    }

    /// Copies a complete proposed record. A null expected revision creates a
    /// freshly allocated object; otherwise the backend compares the existing row.
    pub fn putCopying(self: *Store, record: Record, expected: ?u64) !void {
        try self.admit(record.id);
        if (expected == null and (record.id.incarnation != self.metadata.incarnation or record.id.sequence > self.object_sequence or record.id.sequence <= self.creation_floor)) return error.InvalidObject;
        var proposed = record;
        proposed.revision = self.metadata.revision + 1;
        var bounded = self.limits.records;
        bounded.max_record_bytes = @min(bounded.max_record_bytes, self.limits.staging_bytes - self.staged_bytes);
        const bytes = try proposed.encodeAlloc(self.allocator, bounded, self.cache.schemas);
        errdefer self.allocator.free(bytes);
        if (bytes.len > self.limits.staging_bytes - self.staged_bytes) return error.StagingCapacity;
        self.changes[self.count] = .{ .id = record.id, .expected = expected, .bytes = bytes };
        self.count += 1;
        self.staged_bytes += bytes.len;
    }

    pub fn remove(self: *Store, id: ObjectId, expected: u64) !void {
        try self.admit(id);
        self.changes[self.count] = .{ .id = id, .expected = expected, .bytes = null };
        self.count += 1;
    }

    pub fn prepare(self: *Store) !Ticket {
        if (self.phase != .staging or self.count == 0) return error.WrongPhase;
        self.digest = Batch.fingerprint(self.ticket.?, self.changes[0..self.count], null);
        self.phase = .prepared;
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
    pub fn beginWrite(self: *Store, ticket: Ticket) !Batch {
        try self.match(ticket, .prepared);
        self.phase = .writing;
        return self.batch();
    }

    pub fn completeWrite(self: *Store, ticket: Ticket, outcome: Outcome) !void {
        try self.match(ticket, .writing);
        switch (outcome) {
            .unknown => self.phase = .uncertain,
            .unchanged => self.discard(),
            .committed => |meta| try self.install(meta),
        }
    }

    pub fn recoveryBatch(self: *Store) !Batch {
        if (self.phase != .uncertain) return error.WrongPhase;
        return self.batch();
    }

    /// Recovery runs only after the original worker has terminated. A missing
    /// receipt cannot prove absence while that worker could still commit.
    pub fn resolve(self: *Store, ticket: Ticket, resolution: Resolution) !void {
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

    fn admit(self: *Store, id: ObjectId) !void {
        if (self.phase != .staging) return error.WrongPhase;
        if (id.store != self.metadata.store) return error.ForeignObject;
        if (self.count == self.changes.len) return error.ChangeCapacity;
        for (self.changes[0..self.count]) |change| if (change.id.eql(id)) return error.DuplicateMutation;
    }

    fn match(self: *Store, ticket: Ticket, phase: @FieldType(Store, "phase")) !void {
        if (self.ticket == null or !std.meta.eql(self.ticket.?, ticket)) return error.StaleCompletion;
        if (self.phase != phase) return error.WrongPhase;
    }

    fn batch(self: *Store) Batch {
        return .{ .ticket = self.ticket.?, .digest = self.digest, .changes = self.changes[0..self.count], .limits = self.limits.records, .schemas = self.cache.schemas, .collection = self.collection_work };
    }

    fn install(self: *Store, meta: Metadata) !void {
        self.phase = .uncertain;
        const resolution = try self.batch().resolve(meta);
        if (resolution != .committed) return error.RecoveryRequired;
        self.cache.install(self.metadata, meta, self.changes[0..self.count], self.collection_work != null);
        self.metadata = meta;
        if (self.retain_committed) for (self.changes[0..self.count]) |*change| {
            if (change.bytes) |bytes| {
                if (self.cache.adoptCommitted(meta, change.id, @constCast(bytes))) change.bytes = null;
            }
        };
        self.discard();
    }

    fn discard(self: *Store) void {
        if (self.collection_work) |work| {
            self.allocator.free(work.roots);
            self.allocator.free(work.scratch);
            self.collection_work = null;
        }
        for (self.changes[0..self.count]) |change| if (change.bytes) |bytes| self.allocator.free(bytes);
        self.count = 0;
        self.staged_bytes = 0;
        self.ticket = null;
        self.retain_committed = false;
        self.phase = .idle;
    }

    /// Keep an object and its strong graph alive independently of residency.
    /// This is privileged local custody. Callers must still obtain remote
    /// authority through Host capabilities, never by presenting this token.
    pub fn retain(self: *Store, id: ObjectId) !Retention {
        if (self.phase == .uncertain) return error.RecoveryRequired;
        if (self.collection_work != null) return error.Busy;
        return self.retentions.retain(self.metadata, id);
    }

    pub fn releaseRetention(self: *Store, token: Retention) !void {
        try self.retentions.release(self.metadata, token);
    }

    /// Prepare a bounded tracing batch. Execute and settle it through the
    /// ordinary beginWrite/completeWrite/recovery path. New leases and live
    /// retention claims wait until completion; existing leases remain usable.
    pub fn prepareCollection(self: *Store, work_limit: usize) !Ticket {
        if (work_limit == 0) return error.InvalidLimits;
        try self.begin();
        errdefer self.discard();
        var roots: std.ArrayList(ObjectId) = .empty;
        errdefer roots.deinit(self.allocator);
        for (self.retentions.entries) |entry| if (entry.sequence != 0) try self.addCollectionRoot(&roots, entry.id);
        for (self.cache.slots) |slot| {
            if (slot.id == null or (slot.pins == 0 and slot.loading == null)) continue;
            try self.addCollectionRoot(&roots, slot.id.?);
            if (slot.loading == null) {
                const portrait = try RecordView.decode(slot.bytes.?[0..slot.length], self.limits.records, self.cache.schemas);
                // A pinned historical portrait can still expose its old edges.
                var edges = portrait.edges();
                while (edges.next()) |edge| if (edge.strength == .strong) try self.addCollectionRoot(&roots, edge.target);
            }
        }
        const scratch = try self.allocator.alloc(u8, self.limits.records.max_record_bytes);
        errdefer self.allocator.free(scratch);
        const owned = try roots.toOwnedSlice(self.allocator);
        self.collection_work = .{ .roots = owned, .work_limit = work_limit, .scratch = scratch };
        self.digest = Batch.fingerprint(self.ticket.?, &.{}, self.collection_work);
        self.phase = .prepared;
        return self.ticket.?;
    }

    fn addCollectionRoot(self: *Store, roots: *std.ArrayList(ObjectId), id: ObjectId) !void {
        if (roots.items.len == self.limits.max_collection_roots) return error.RetentionCapacity;
        try roots.append(self.allocator, id);
    }
};
