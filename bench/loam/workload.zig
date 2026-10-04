//! A local conversation graph over the shipped actor and LMDB interfaces.
//! Only conversation headers have actor endpoints; message records stay cold.
const std = @import("std");
const glowcap = @import("glowcap");
pub const core = glowcap.loam.core;
pub const hosting = glowcap.loam.hosting;
pub const driver = glowcap.driver.core;
pub const Lmdb = @import("loam_lmdb").Lmdb;
const actors = glowcap.actors;
const executor = @import("executor.zig");
pub const cache_slots = 16;
pub const messages_per_conversation = 4;
const schemas = [_]core.Schema{
    .{ .id = 1, .version = 1, .max_payload = 128, .max_edges = 1 },
    .{ .id = 2, .version = 1, .max_payload = 4096, .max_edges = 2 },
    hosting.publication.schema,
};
const behaviors = [_]hosting.Behavior{.{ .schema = 1, .invoke = conversation }};

fn conversation(call: *hosting.Call, view: core.RecordView, verb: []const u8, args: []const driver.Value) !driver.Value {
    if (view.payload.len != 128 or args.len != 0) return error.InvalidArguments;
    const version = std.mem.readInt(i64, view.payload[0..8], .little);
    if (std.mem.eql(u8, verb, "read")) return .{ .integer = version };
    if (!std.mem.eql(u8, verb, "edit")) return error.NoSuchMethod;
    const next = try std.math.add(i64, version, 1);
    const bytes = try call.arena.dupe(u8, view.payload);
    std.mem.writeInt(i64, bytes[0..8], next, .little);
    call.replace(bytes);
    return .{ .integer = next };
}

pub const Answer = struct {
    value: ?i64 = null,
    failed: bool = false,
    reason: [64]u8 = undefined,
    reason_len: usize = 0,
    pub fn receive(ctx: ?*anyopaque, result: actors.Resolution) void {
        const self: *Answer = @ptrCast(@alignCast(ctx.?));
        switch (result) {
            .fulfilled => |value| self.value = value.integer,
            .broken => |reason| {
                self.reason_len = @min(reason.len, self.reason.len);
                @memcpy(self.reason[0..self.reason_len], reason[0..self.reason_len]);
                self.failed = true;
            },
            .give => self.failed = true,
        }
    }
    pub fn require(self: Answer) !i64 {
        if (self.failed) {
            std.debug.print("loam benchmark call failed: {s}\n", .{self.reason[0..self.reason_len]});
            return error.CallFailed;
        }
        return self.value orelse error.NoAnswer;
    }
};

pub const Workload = struct {
    store: core.Store,
    host: driver.Host,
    attachment: *hosting.Attachment,
    db: *Lmdb,
    caps: []driver.Capability,
    ids: []core.ObjectId,
    allocator: std.mem.Allocator,
    reads: u64 = 0,
    lookups: u64 = 0,
    writes: u64 = 0,

    pub fn init(self: *Workload, allocator: std.mem.Allocator, db: *Lmdb, count: usize, payload_bytes: usize) !void {
        self.* = .{
            .store = try core.Store.init(allocator, db.metadata, &schemas, .{
                .records = .{ .max_record_bytes = 8192, .max_edges = 2 },
                .cache_slots = cache_slots,
                .max_leases = 64,
                .resident_bytes = cache_slots * 8192,
                .max_changes = 8,
                .staging_bytes = 64 * 1024,
                .max_retentions = count,
                .max_collection_roots = count + 128,
            }),
            .host = undefined,
            .attachment = undefined,
            .caps = undefined,
            .ids = undefined,
            .db = db,
            .allocator = allocator,
        };
        errdefer self.store.deinit() catch unreachable;
        // Deterministic identity is confined to this local, socket-free bench.
        self.host = try driver.Host.init(allocator, @splat(0x81), @splat(0x82), driver.Host.Options.withFrameCap(4096));
        errdefer self.host.deinit();
        self.caps = try allocator.alloc(driver.Capability, count);
        errdefer allocator.free(self.caps);
        self.ids = try allocator.alloc(core.ObjectId, count);
        errdefer allocator.free(self.ids);
        self.attachment = try hosting.Attachment.create(allocator, &self.host, &self.store, &behaviors, .{
            .max_endpoints = count,
            .max_calls = 64,
            .call_bytes = 4096,
            .pending_bytes = 256 * 1024,
        });
        errdefer self.attachment.destroy() catch unreachable;
        var populated: usize = 0;
        errdefer for (self.caps[0..populated]) |cap| self.host.releaseCapability(cap, 1) catch unreachable;
        const payload: [4096]u8 = @splat('m');
        for (self.ids, 0..) |*id, index| {
            try self.store.begin();
            errdefer if (self.store.phase == .staging) self.store.abort() catch unreachable;
            id.* = try self.store.allocateId();
            var previous: ?core.ObjectId = null;
            for (0..messages_per_conversation) |_| {
                const message = try self.store.allocateId();
                var edges: [2]core.Edge = undefined;
                edges[0] = .{ .target = id.*, .strength = .weak };
                if (previous) |prior| edges[1] = .{ .target = prior };
                try self.store.putCopying(.{
                    .id = message,
                    .revision = 0,
                    .schema = 2,
                    .payload = payload[0..payload_bytes],
                    .edges = edges[0..if (previous == null) @as(usize, 1) else 2],
                }, null);
                previous = message;
            }
            try self.store.putCopying(.{
                .id = id.*,
                .revision = 0,
                .schema = 1,
                .rooted = true,
                .payload = &@as([128]u8, @splat(0)),
                .edges = &.{.{ .target = previous.? }},
            }, null);
            try self.finish(try self.store.prepare());
            const lease = try self.load(id.*);
            defer self.store.release(lease) catch unreachable;
            self.caps[index] = try self.attachment.restore(lease);
            populated += 1;
        }
        self.store.evict();
    }

    pub fn deinit(self: *Workload) void {
        for (self.caps) |cap| self.host.releaseCapability(cap, 1) catch unreachable;
        self.attachment.destroy() catch unreachable;
        self.host.deinit();
        self.store.deinit() catch unreachable;
        self.allocator.free(self.ids);
        self.allocator.free(self.caps);
    }

    pub const load = executor.load;

    pub const finish = executor.finish;

    pub fn send(self: *Workload, index: usize, verb: []const u8, answer: *Answer) !void {
        _ = try self.host.vat.sendObservedFromIngress(.local, self.host.localActorFor(self.caps[index]).?, .{ .verb = verb }, .{ .ctx = answer, .func = Answer.receive });
    }

    pub const drain = executor.drain;

    pub fn call(self: *Workload, index: usize, verb: []const u8) !i64 {
        var answer: Answer = .{};
        try self.send(index, verb, &answer);
        try self.drain();
        return answer.require();
    }

    pub fn garbage(self: *Workload, count: usize) !void {
        for (0..count) |_| {
            try self.store.begin();
            const a = try self.store.allocateId();
            const b = try self.store.allocateId();
            for ([_]core.ObjectId{ a, b }, [_]core.ObjectId{ b, a }) |id, other| {
                try self.store.putCopying(.{ .id = id, .revision = 0, .schema = 2, .payload = "abandoned draft", .edges = &.{.{ .target = other }} }, null);
            }
            try self.finish(try self.store.prepare());
        }
    }
};
