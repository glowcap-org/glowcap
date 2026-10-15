//! The board's store and the Loam attachment that serves it.
//!
//! The first start creates the board, publishes it under a secret durable
//! name, and records both in one settings record. Every later start finds that
//! record by its fixed name and serves the same board under the same name.
//! The attachment asks for reads and writes, and `pump` runs them against
//! the storage engine on this thread, so a reply leaves only after its write
//! commits.
const std = @import("std");
const glowcap = @import("glowcap");
/// The board's records and behaviors, for callers that size their work by them.
pub const board = @import("board.zig");
const core = glowcap.loam.core;
const hosting = glowcap.loam.hosting;
const access = glowcap.loam.access;
const driver = glowcap.driver.core;

/// The settings record: which board this store serves and its published name.
/// Its fixed all-zero name lets a restart find it with one lookup.
const settings_schema: core.Schema = .{ .id = 0x5441534b53534554, .version = 1, .max_payload = 16, .max_edges = 3, .name_offset = 0 };
const settings_name: [16]u8 = @splat(0);

const schemas = access.hosting.system_schemas ++ board.schemas ++ [_]core.Schema{settings_schema};
/// A full list's record, its name and `max_tasks` fields, fits in this.
const max_record_bytes = 16 * 1024;
/// Capabilities clients may hold at once across every session: each list and
/// task on a full board once, and as many again for shares, watchers, and
/// other clients. Each one keeps an endpoint live and its record retained.
const max_live = 2 * (1 + board.max_lists * (1 + board.max_tasks));
const cache_slots = (core.Store.Limits{}).cache_slots;
const limits: core.Store.Limits = .{
    .records = .{ .max_record_bytes = max_record_bytes, .max_edges = board.max_tasks },
    .max_retentions = max_live,
    // A collection pass roots every retention and every cached record with
    // its edges.
    .max_collection_roots = max_live + cache_slots * (1 + board.max_tasks),
};
/// Every Tasks store carries this identity, and opening checks it.
const store_id: core.StoreId = @fromBackingInt(0x5441534b53);

/// The lists a new board starts with. Marking a task done moves it from the
/// first to the second.
const first_lists = [_][]const u8{ "To do", "Done" };
/// One call's working memory. Moving a task between two full lists holds both
/// lists and the task, each up to `max_record_bytes`, with their staged
/// copies.
const call_bytes = 8 * max_record_bytes;
/// Every call the attachment admits at once can hold its full working memory.
const pending_bytes = (hosting.Options{}).max_calls * call_bytes;
/// Room for one startup reply: an integer or the new list's capability.
const reply_bytes = 1024;

/// What `pump` has asked the backend to do since the store opened.
pub const Tally = struct { reads: u64 = 0, lookups: u64 = 0, commits: u64 = 0 };

/// The board's storage over `Engine`, a disk engine that opens at a directory
/// with a mode and its default options, as `Lmdb` and `Sqlite` do.
pub fn Storage(comptime Engine: type) type {
    return struct {
        const Self = @This();
        io: std.Io,
        db: Engine,
        store: core.Store,
        caps: access.storage.Capabilities,
        service: access.hosting.Service,
        contents: [board.contents.len]access.hosting.ContentBehavior,
        behaviors: [access.hosting.Service.behavior_count]hosting.Behavior,
        attached: *hosting.Attachment,
        slot: [1]hosting.Worker.Slot,
        worker: hosting.Worker,
        /// The root use descriptor that every created list and task is stored under.
        descriptor: core.ObjectId,
        /// The board's use endpoint, which `restoreRoot` restores.
        use: core.ObjectId,
        /// Backend work `pump` has run, for callers that measure it.
        tally: Tally = .{},
        /// The secret durable name clients fetch the board by.
        name: driver.Host.DurableSwiss,

        /// Open `path` (an existing directory) and serve its board on `host`.
        /// The attachment keeps pointers into this value, so it stays at its
        /// address until `close`.
        pub fn open(self: *Self, allocator: std.mem.Allocator, io: std.Io, host: *driver.Host, path: [:0]const u8) !void {
            self.io = io;
            self.db = try Engine.open(path, .{ .mode = .{ .bootstrap = store_id } });
            errdefer self.db.close() catch {}; // tolerant: the open already failed.
            self.store = try core.Store.init(allocator, self.db.metadata, &schemas, limits);
            errdefer self.store.deinit() catch {}; // tolerant: the open already failed.
            const found = try self.findSettings() orelse try self.create();
            self.use = found.use;
            self.tally = .{};
            self.descriptor = try self.read(found.use, useDescriptor);
            self.name = try self.read(found.publication, publishedName);
            self.caps = try access.storage.Capabilities.init(allocator, &self.store, .{});
            errdefer self.caps.deinit() catch {}; // tolerant: the open already failed.
            self.contents = board.contents;
            self.service = .{ .capabilities = &self.caps, .contents = &self.contents, .context = self, .child_descriptor = childDescriptor, .decode_control = access.hosting.vocabulary.edit, .decode_control_revision = access.hosting.vocabulary.revision, .decode_derive = access.hosting.vocabulary.derive, .decode_managed_derive = access.hosting.vocabulary.managed, .decode_attenuation = access.hosting.vocabulary.attenuate, .entropy = .{ .context = self, .fill = fill } };
            self.behaviors = self.service.behaviors();
            self.attached = try hosting.Attachment.create(allocator, host, &self.store, &self.behaviors, .{ .call_bytes = call_bytes, .pending_bytes = pending_bytes, .max_endpoints = max_live });
            errdefer self.attached.destroy() catch {}; // tolerant: the open already failed.
            try hosting.publication.listen(self.attached, .{});
            self.worker = .init(&self.slot, self.db.readerCapacity());
            try self.addFirstLists(allocator);
        }

        /// Close every part even when one fails, and report the first failure.
        pub fn close(self: *Self) !void {
            var first: ?anyerror = null;
            self.attached.destroy() catch |err| {
                first = first orelse err;
            };
            self.caps.deinit() catch |err| {
                first = first orelse err;
            };
            self.store.deinit() catch |err| {
                first = first orelse err;
            };
            self.db.close() catch |err| {
                first = first orelse err;
            };
            if (first) |err| return err;
        }

        /// Run the board's local calls, the attachment's progress, and every read
        /// and write it asks for, counting them in `tally`, until a pass leaves no
        /// local turn pending, finds no attachment progress, and runs no storage
        /// request. Such a pass is waiting on something outside this process, so
        /// repeating it would spin.
        pub fn pump(self: *Self) !void {
            for (0..64) |_| {
                var progressed = try self.attached.host.vat.driveIngressBudgeted(.local, 64) == .more_pending;
                progressed = (try self.attached.advanceProgress()) or progressed;
                while (try self.worker.next(self.attached, false)) |slot| {
                    progressed = true;
                    hosting.Worker.run(slot, &self.db) catch unreachable; // `next` just filled this slot.
                    switch (slot.request) {
                        .read => self.tally.reads += 1,
                        .lookup => self.tally.lookups += 1,
                        .write => if (slot.result.?.write == .committed) {
                            self.tally.commits += 1;
                        },
                        .recover => {},
                    }
                    const installed = self.worker.complete(slot, self.attached);
                    // `next` passed the top-level check on this stack, so `complete` consumed the slot.
                    self.worker.release(slot) catch unreachable;
                    try installed;
                }
                if (!progressed) return;
            }
        }

        const Settings = struct { use: core.ObjectId, publication: core.ObjectId };

        fn findSettings(self: *Self) !?Settings {
            const meta = self.store.metadata;
            const id = switch (self.db.lookup(.{ .ticket = .{ .store = meta.store, .incarnation = meta.incarnation, .sequence = 0, .revision = meta.revision }, .name = .{ .schema = settings_schema.id, .bytes = settings_name } })) {
                .found => |id| id,
                .missing => return null,
                .failed => |err| return err,
            };
            return try self.read(id, decodeSettings);
        }

        fn decodeSettings(record: core.RecordView) !Settings {
            if (record.schema != settings_schema.id or record.edge_count != 3) return error.InvalidSettings;
            return .{ .use = (try record.edgeAt(0)).target, .publication = (try record.edgeAt(2)).target };
        }

        /// Stage the owner, its board, the board's published name, and the
        /// settings record in one transaction.
        fn create(self: *Self) !Settings {
            var owner: [16]u8 = undefined;
            try self.io.randomSecure(&owner);
            var secret: hosting.publication.Entropy = undefined;
            try self.io.randomSecure(&secret);
            try self.store.begin();
            errdefer self.store.abort() catch {}; // tolerant: nothing was written.
            const staged = try access.hosting.stageOwner(&self.store, .{ .id = @fromBackingInt(std.mem.readInt(u128, &owner, .big)), .policy = try access.core.Policy.init(board.policy), .kind = board.kind, .schema = board.board_schema, .payload = "Tasks", .delegation_depth = 8, .scope = .subtree });
            const publication = try hosting.publication.stageTarget(&self.store, secret, staged.use);
            try self.store.putCopying(.{ .id = try self.store.allocateId(), .revision = 0, .schema = settings_schema.id, .rooted = true, .payload = &settings_name, .edges = &.{ .{ .target = staged.use }, .{ .target = staged.control }, .{ .target = publication } } }, null);
            const ticket = try self.store.prepare();
            const outcome = self.db.commit(try self.store.beginWrite(ticket));
            try self.store.completeWrite(ticket, outcome);
            if (outcome != .committed) return error.CommitFailed;
            return .{ .use = staged.use, .publication = publication };
        }

        /// Add whichever first lists the board does not have yet, through the
        /// same hosted calls a client makes. A start that stopped partway
        /// finishes the job.
        fn addFirstLists(self: *Self, allocator: std.mem.Allocator) !void {
            const root = try self.restoreRoot();
            defer self.attached.host.releaseCapability(root, 1) catch {}; // tolerant: teardown releases the actor.
            const have: usize = @intCast(try self.integer(allocator, root, "lists", &.{}));
            for (first_lists[@min(have, first_lists.len)..]) |name| {
                const sequence = try self.integer(allocator, root, "mutation-sequence", &.{});
                (try self.call(allocator, root, "mutate", &.{ .{ .integer = sequence }, .{ .string = "add-list" }, .{ .string = name } }, reply_bytes)).deinit();
            }
        }

        /// The board's root capability, held until the caller releases it with
        /// `host.releaseCapability`.
        pub fn restoreRoot(self: *Self) !driver.Capability {
            const held = try self.lease(self.use);
            defer self.store.release(held) catch {}; // tolerant: the restore below holds its own retain.
            return self.attached.restore(held);
        }

        /// One local call to a hosted endpoint, driven with the storage work it
        /// needs. The reply, which may take up to `reply_capacity` bytes, and any
        /// capability in it belong to the returned call, which the caller releases
        /// with `deinit`.
        pub fn call(self: *Self, allocator: std.mem.Allocator, target: driver.Capability, verb: []const u8, args: []const driver.Value, reply_capacity: usize) !*driver.Host.Call {
            const owned = try self.attached.host.callLocalCapability(allocator, target, verb, args, reply_capacity);
            errdefer owned.deinit();
            for (0..64) |_| {
                try self.pump();
                switch (owned.result()) {
                    .pending => {},
                    .ready => return owned,
                    .failed => return error.Refused,
                }
            }
            return error.DidNotSettle;
        }

        fn integer(self: *Self, allocator: std.mem.Allocator, target: driver.Capability, verb: []const u8, args: []const driver.Value) !i64 {
            const owned = try self.call(allocator, target, verb, args, reply_bytes);
            defer owned.deinit();
            const value = owned.result().ready;
            return if (value == .integer) value.integer else error.NotAnInteger;
        }

        fn lease(self: *Self, id: core.ObjectId) !core.Lease {
            return switch (try self.store.acquire(id)) {
                .ready => |held| held,
                .read => |request| blk: {
                    try self.store.completeRead(request.ticket, self.db.read(request));
                    break :blk (try self.store.acquire(id)).ready;
                },
            };
        }

        /// Decode one record into a value while its lease is held.
        fn read(self: *Self, id: core.ObjectId, comptime decode: anytype) !@typeInfo(@typeInfo(@TypeOf(decode)).@"fn".return_type.?).error_union.payload {
            const held = try self.lease(id);
            defer self.store.release(held) catch {}; // tolerant: a startup read retains nothing.
            return decode(try self.store.currentView(held));
        }
        fn childDescriptor(context: ?*anyopaque, _: access.core.OwnerId) ?core.ObjectId {
            const self: *Self = @ptrCast(@alignCast(context.?));
            return self.descriptor;
        }

        fn fill(context: ?*anyopaque, bytes: *driver.Host.DurableSwiss.Entropy) !void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            try self.io.randomSecure(bytes);
        }
    };
}

fn useDescriptor(record: core.RecordView) !core.ObjectId {
    return (try access.records.EndpointRecord.decode(record)).descriptor;
}

fn publishedName(record: core.RecordView) !driver.Host.DurableSwiss {
    _ = try hosting.publication.activeTarget(record);
    return driver.Host.DurableSwiss.fromEntropy(record.payload[0..@sizeOf(hosting.publication.Entropy)].*);
}
