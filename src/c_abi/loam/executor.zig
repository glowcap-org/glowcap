//! The engine-independent bodies of a storage archive's symbols. An archive
//! instantiates them once for its engine and supplies only how it opens.
const std = @import("std");
const c = @import("mod.zig");
const bridge = c.embedding;
const shared = @import("c_abi_shared");
const loam = @import("loam_core");
const allocator = shared.library_allocator;

/// The owner an archive hands out as its opaque handle: the engine and the
/// Store it serves, with the execution bodies that drive both. The engine
/// needs the four backend operations, its claimed `metadata`, and `close`.
/// Workers call it from the storage executor's threads while the Host thread
/// commits, so an engine whose calls must not overlap is wrapped first.
pub fn Executor(comptime Engine: type) type {
    comptime loam.backend.checkBackend(Engine);
    return struct {
        engine: Engine,
        store: *bridge.Store,
        const Self = @This();

        /// The body of an archive's open symbol. `opener` is a value with
        /// `open(identity, mode)` returning the opened engine, and it touches
        /// storage only after every argument here is checked. A refusal leaves
        /// both out slots null.
        pub fn open(store_id: ?[*]const u8, create: u32, schemas: ?[*]const c.GlowcapLoamSchema, schema_count: usize, limits: ?*const c.GlowcapLoamLimits, out_storage: ?*?*anyopaque, out_store: ?*?*c.GlowcapLoamStore, opener: anytype) i32 {
            shared.lastErrorClear();
            const storage_slot = out_storage orelse return shared.GLOWCAP_ERR_NULL_POINTER;
            storage_slot.* = null;
            const store_slot = out_store orelse return shared.GLOWCAP_ERR_NULL_POINTER;
            store_slot.* = null;
            const id = store_id orelse return shared.GLOWCAP_ERR_NULL_POINTER;
            const bounds = limits orelse return shared.GLOWCAP_ERR_NULL_POINTER;
            const mode = std.enums.fromInt(loam.OpenMode, create) orelse return bridge.code(error.InvalidArgument);
            const declarations = bridge.slice(c.GlowcapLoamSchema, schemas, schema_count) catch |err| return bridge.code(err);
            bridge.Store.validateConfiguration(declarations, bounds.*) catch |err| return bridge.code(err);
            const identity: loam.StoreId = @fromBackingInt(std.mem.readInt(u128, id[0..16], .big));
            const owner = allocator.create(Self) catch |err| return bridge.code(err);
            const engine = opener.open(identity, mode) catch |err| {
                allocator.destroy(owner);
                return bridge.code(err);
            };
            owner.adopt(engine, declarations, bounds.*) catch |err| return bridge.code(err);
            storage_slot.* = owner;
            store_slot.* = @ptrCast(owner.store);
            return shared.GLOWCAP_OK;
        }

        /// Opens a disk engine at a caller's path, with the archive's size
        /// argument as the engine option `size_field` and every other option
        /// at the engine's default.
        pub fn Disk(comptime size_field: []const u8) type {
            return struct {
                path: ?[*]const u8,
                path_len: usize,
                size: usize,

                pub fn open(self: @This(), identity: loam.StoreId, mode: loam.OpenMode) !Engine {
                    const path_slice = try shared.sliceFromC(self.path, self.path_len);
                    if (std.mem.indexOfScalar(u8, path_slice, 0) != null) return error.InvalidArgument;
                    const owned_path = try allocator.dupeSentinel(u8, path_slice, 0);
                    defer allocator.free(owned_path);
                    var options: Engine.Options = .{ .opening = .{ .id = identity, .mode = mode } };
                    @field(options, size_field) = self.size;
                    return Engine.open(owned_path, options);
                }
            };
        }

        /// Adopt an opened engine into an owner allocated before the engine
        /// opened, so an allocation failure touched no storage, by building the
        /// Store over the engine's metadata. A refusal closes the engine and
        /// frees the owner.
        fn adopt(owner: *Self, engine: Engine, declarations: []const c.GlowcapLoamSchema, bounds: c.GlowcapLoamLimits) !void {
            var opened = engine;
            const store = bridge.Store.init(allocator, opened.metadata, declarations, bounds) catch |err| {
                // best-effort: a failing close is dropped in favor of the Store refusal, leaving at most the engine's own handle unreleased.
                closeEngine(&opened) catch {};
                allocator.destroy(owner);
                return err;
            };
            store.backend_owned = true;
            store.readers = opened.readerCapacity();
            owner.* = .{ .engine = opened, .store = store };
        }

        /// The owner behind an archive's opaque handle.
        pub fn from(raw: ?*anyopaque) !*Self {
            return @ptrCast(@alignCast(raw orelse return error.NullPointer));
        }

        /// Release a handle. A null handle is already released. A refused Store
        /// teardown keeps the handle for a retry, and a failing engine close frees
        /// the handle and reports the failure.
        pub fn release(raw: ?*anyopaque) i32 {
            shared.lastErrorClear();
            if (raw == null) return shared.GLOWCAP_OK;
            const self = from(raw) catch |err| return bridge.code(err);
            self.store.destroy() catch |err| return bridge.code(err);
            const closed = closeEngine(&self.engine);
            allocator.destroy(self);
            closed catch |err| return bridge.code(err);
            return shared.GLOWCAP_OK;
        }

        /// Execute on the embedding's storage executor. Join it before completing or
        /// releasing the work on the Host thread. No Host or attachment is touched.
        pub fn workRun(self: *Self, work_handle: ?*c.GlowcapLoamWork) i32 {
            shared.lastErrorClear();
            const work = bridge.work(work_handle) catch |err| return bridge.code(err);
            if (work.owner.store != self.store) return bridge.code(error.StaleCompletion);
            bridge.Worker.run(work.slot, &self.engine) catch |err| return bridge.code(err);
            return shared.GLOWCAP_OK;
        }

        /// Restore from trusted persisted metadata. The ordinary Store read checks the
        /// full record before the attachment mints one held Host capability occurrence.
        pub fn restore(self: *Self, attachment: ?*c.GlowcapLoamAttachment, object: ?*const c.GlowcapLoamObject, out_ref: ?*shared.GlowcapReference) i32 {
            shared.lastErrorClear();
            const attached = bridge.attachment(attachment) catch |err| return bridge.code(err);
            const source = object orelse return shared.GLOWCAP_ERR_NULL_POINTER;
            const target = out_ref orelse return shared.GLOWCAP_ERR_NULL_POINTER;
            if (attached.store != self.store) return bridge.code(error.ForeignStore);
            attached.value.topLevel() catch |err| return bridge.code(err);
            const id = bridge.object(source.*) catch |err| return bridge.code(err);
            const lease = self.load(id) catch |err| return bridge.code(err);
            defer self.store.value.release(lease) catch unreachable;
            const ref = attached.value.restore(lease) catch |err| return bridge.code(err);
            target.* = .{ .id = ref.raw() };
            return shared.GLOWCAP_OK;
        }

        fn load(self: *Self, id: loam.ObjectId) !loam.Lease {
            return switch (try self.store.value.acquire(id)) {
                .ready => |lease| lease,
                .read => |request| blk: {
                    try self.store.value.completeRead(request.ticket, self.engine.read(request));
                    break :blk (try self.store.value.acquire(id)).ready;
                },
            };
        }

        pub fn commit(self: *Self) i32 {
            return self.run(null);
        }

        /// Run one bounded collection batch and commit it like `commit`.
        pub fn collect(self: *Self, work_limit: usize) i32 {
            return self.run(work_limit);
        }

        fn run(self: *Self, collection: ?usize) i32 {
            shared.lastErrorClear();
            if (self.store.attachments != 0) return bridge.code(error.Busy);
            const store = &self.store.value;
            const ticket = (if (collection) |limit| store.prepareCollection(limit) else store.prepare()) catch |err| {
                // A refused commit retires the staged batch it was asked to commit. A
                // refused collection touched no staging of the caller's.
                if (collection == null and (store.phase == .staging or store.phase == .prepared)) store.abort() catch unreachable;
                return bridge.code(err);
            };
            const batch = store.beginWrite(ticket) catch |err| return bridge.code(err);
            const outcome = self.engine.commit(batch);
            store.completeWrite(ticket, outcome) catch |err| {
                if (store.phase == .uncertain) return bridge.code(error.RecoveryRequired);
                return bridge.code(err);
            };
            switch (outcome) {
                .committed => {},
                .unchanged => |err| {
                    // Preserve the storage cause. The result family describes the
                    // proven terminal outcome, not invalid application arguments.
                    _ = bridge.code(err);
                    return c.GLOWCAP_LOAM_ERR_UNCHANGED;
                },
                .unknown => return bridge.code(error.OutcomeUnknown),
            }
            return shared.GLOWCAP_OK;
        }

        /// Resolve unattached creation only after its commit worker has terminated.
        pub fn recover(self: *Self) i32 {
            shared.lastErrorClear();
            if (self.store.attachments != 0) return bridge.code(error.Busy);
            const store = &self.store.value;
            const batch = store.recoveryBatch() catch |err| return bridge.code(err);
            const resolution = self.engine.recover(batch) catch |err| return bridge.code(err);
            store.resolve(batch.ticket, resolution) catch |err| return bridge.code(err);
            return if (resolution == .committed) shared.GLOWCAP_OK else c.GLOWCAP_LOAM_ERR_UNCHANGED;
        }

        /// Close with the engine's own result shape. Every caller holds an engine
        /// with no transaction open, so a busy refusal cannot occur, and any other
        /// failure is the engine's own I/O report.
        fn closeEngine(engine: *Engine) !void {
            if (@typeInfo(@typeInfo(@TypeOf(Engine.close)).@"fn".return_type.?) == .error_union) {
                try engine.close();
            } else engine.close();
        }
    };
}
