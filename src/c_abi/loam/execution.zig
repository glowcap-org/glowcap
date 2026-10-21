//! Synchronous transaction evaluation for embedding-owned atomic KV stores.
//! A missing row or key walk suspends the batch, and earlier writes stay in the same transaction. status-allow: event or source ordering
//! Put and remove consume their bytes synchronously, and a returned row lasts until the next callback.
//! Only a terminal database event retires a plan and permits installation.
const std = @import("std");
const common = @import("common.zig");
const work = @import("work.zig");
const core = common.core;
pub const GlowcapLoamBytes = extern struct { data: ?[*]const u8 = null, len: usize = 0, present: u32 = 0 };
pub const GlowcapLoamKvFn = *const fn (?*anyopaque, u32, ?[*]const u8, usize, ?*const GlowcapLoamBytes, ?*GlowcapLoamBytes) callconv(.c) i32;
pub const Kv = struct {
    callback: GlowcapLoamKvFn,
    context: ?*anyopaque,
    /// The key a walk last returned, kept so its row can be read back.
    key: [core.max_key_bytes]u8 = undefined,
    fn call(self: *Kv, op: u32, key: []const u8, input: ?*const GlowcapLoamBytes, output: ?*GlowcapLoamBytes) !void {
        switch (self.callback(self.context, op, key.ptr, key.len, input, output)) {
            common.shared.GLOWCAP_OK => {},
            common.shared.GLOWCAP_ERR_WOULD_BLOCK => return if (op == 0 or op == 3) error.RecordUnloaded else error.WriteWouldBlock,
            else => return error.StorageFailure,
        }
    }
    pub fn get(self: *Kv, key: []const u8) !?[]const u8 {
        var out: GlowcapLoamBytes = .{};
        try self.call(0, key, null, &out);
        if (out.present > 1) return error.InvalidArgument;
        if (out.present == 0) return null;
        return try common.slice(u8, out.data, out.len);
    }
    pub fn put(self: *Kv, key: []const u8, value: []const u8) !void {
        const bytes: GlowcapLoamBytes = .{ .data = value.ptr, .len = value.len, .present = 1 };
        try self.call(1, key, &bytes, null);
    }
    pub fn remove(self: *Kv, key: []const u8) !void {
        try self.call(2, key, null, null);
    }
    /// The first row under `prefix` strictly after `after`, in key order. The
    /// embedding answers the key and the row is read back through `get`.
    pub fn next(self: *Kv, prefix: []const u8, after: ?[]const u8) !?core.CollectionRow {
        const floor: GlowcapLoamBytes = if (after) |bytes| .{ .data = bytes.ptr, .len = bytes.len, .present = 1 } else .{};
        var out: GlowcapLoamBytes = .{};
        try self.call(3, prefix, &floor, &out);
        if (out.present > 1) return error.InvalidArgument;
        if (out.present == 0) return null;
        const found = try common.slice(u8, out.data, out.len);
        if (found.len == 0 or found.len > self.key.len or !std.mem.startsWith(u8, found, prefix)) return error.InvalidArgument;
        if (after) |bytes| if (std.mem.order(u8, found, bytes) != .gt) return error.InvalidArgument;
        @memcpy(self.key[0..found.len], found);
        const key = self.key[0..found.len];
        const value = (try self.get(key)) orelse return error.Corrupt;
        return .{ .key = key, .value = value };
    }
};
pub fn claim(identity: []const u8, mode: core.OpenMode, previous: ?[]const u8) !core.Metadata {
    if (identity.len != 16) return error.InvalidArgument;
    const id: core.StoreId = @fromBackingInt(std.mem.readInt(u128, identity[0..16], .big));
    const old = try core.Metadata.select(id, mode, previous);
    return old.claim();
}
pub fn plan(request: work.Request, evaluation: ?*core.Batch.Evaluation, kv: *Kv) !work.Result {
    return switch (request) {
        .write => .{ .write = .{ .committed = try evaluation.?.advance(kv) } },
        .recover => |batch| .{ .recover = try batch.resolve(try core.backend.metadata(kv)) },
        .lookup => |lookup| .{ .lookup = try lookup.read(kv) },
        .read => |read| .{ .read = try core.backend.readRecord(kv, read) },
    };
}
pub fn finish(request: work.Request, planned: ?work.Result, outcome: u32) !work.Result {
    return switch (outcome) {
        0 => planned orelse error.WorkerNotRetired,
        1 => switch (request) {
            .write => .{ .write = .{ .unchanged = error.WriteNotCommitted } },
            .read => .{ .read = .{ .failed = error.StorageFailure } },
            .lookup => .{ .lookup = .{ .failed = error.StorageFailure } },
            .recover => .{ .failed = error.RecoveryRequired },
        },
        2 => if (request == .write) .{ .write = .unknown } else error.InvalidArgument,
        else => error.InvalidArgument,
    };
}
pub fn startupPlan(owner: *common.Store, recovery: bool, kv: *Kv) !void {
    if (owner.attachments != 0) return error.Busy;
    if (owner.store_result != null) return error.Busy;
    if (recovery) {
        const batch = try owner.value.recoveryBatch();
        owner.store_result = try batch.resolve(try core.backend.metadata(kv));
        return;
    }
    if (owner.store_batch) |batch| {
        if (batch.collection != null) return error.Busy;
    } else {
        const ticket = try owner.value.prepare();
        owner.store_batch = try owner.value.beginWrite(ticket);
    }
    try evaluate(owner, kv);
}
/// Evaluate one bounded collection batch of at most `work_limit` steps plus the
/// steps that finish its open unit. `startupFinish` retires it like a write, and
/// a suspended startup write refuses it until that write is finished.
pub fn collectPlan(owner: *common.Store, work_limit: usize, kv: *Kv) !void {
    if (owner.attachments != 0) return error.Busy;
    if (owner.store_result != null) return error.Busy;
    if (owner.store_batch) |batch| {
        if (batch.collection == null) return error.Busy;
    } else {
        const ticket = try owner.value.prepareCollection(work_limit);
        owner.store_batch = try owner.value.beginWrite(ticket);
    }
    try evaluate(owner, kv);
}
fn evaluate(owner: *common.Store, kv: *Kv) !void {
    if (owner.store_evaluation == null) owner.store_evaluation = core.Batch.Evaluation.init(&owner.store_batch.?);
    // Advance into a local first, because a suspended step must leave no result.
    const result: core.Resolution = .{ .committed = try owner.store_evaluation.?.advance(kv) };
    owner.store_result = result;
}
pub fn startupFinish(owner: *common.Store, recovery: bool, outcome: u32) !void {
    if (owner.attachments != 0) return error.Busy;
    if (outcome > 2 or (recovery and outcome == 2)) return error.InvalidArgument;
    if (recovery) {
        if (outcome != 0) {
            owner.store_result = null;
            return error.RecoveryRequired;
        }
        const result = owner.store_result orelse return error.WorkerNotRetired;
        try owner.value.resolve((try owner.value.recoveryBatch()).ticket, result);
        owner.store_batch = null;
        owner.store_evaluation = null;
        owner.store_result = null;
        if (result == .unchanged) return error.WriteNotCommitted;
    } else {
        const batch = owner.store_batch orelse return error.StaleCompletion;
        const result: core.Outcome = switch (outcome) {
            0 => .{ .committed = (owner.store_result orelse return error.WorkerNotRetired).committed },
            1 => .{ .unchanged = error.WriteNotCommitted },
            2 => .unknown,
            else => unreachable,
        };
        defer {
            owner.store_result = null;
            owner.store_evaluation = null;
        }
        owner.value.completeWrite(batch.ticket, result) catch |err| {
            if (owner.value.phase != .uncertain) owner.store_batch = null;
            return err;
        };
        if (owner.value.phase == .uncertain) return error.RecoveryRequired;
        owner.store_batch = null;
        if (outcome == 1) return error.WriteNotCommitted;
    }
}
