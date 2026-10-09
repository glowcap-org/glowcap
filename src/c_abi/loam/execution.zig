//! Synchronous transaction evaluation for embedding-owned atomic KV stores.
//! A missing input suspends the batch cursor; earlier writes stay in the same
//! atomic transaction. Only get suspends; put/remove synchronously consume bytes.
//! Only a terminal database event can retire a plan and permit installation.
const std = @import("std");
const common = @import("common.zig");
const work = @import("work.zig");
const core = common.core;
pub const GlowcapLoamBytes = extern struct { data: ?[*]const u8 = null, len: usize = 0, present: u32 = 0 };
pub const GlowcapLoamKvFn = *const fn (?*anyopaque, u32, ?[*]const u8, usize, ?*const GlowcapLoamBytes, ?*GlowcapLoamBytes) callconv(.c) i32;
pub const Kv = struct {
    callback: GlowcapLoamKvFn,
    context: ?*anyopaque,
    fn call(self: *Kv, op: u32, key: []const u8, input: ?*const GlowcapLoamBytes, output: ?*GlowcapLoamBytes) !void {
        switch (self.callback(self.context, op, key.ptr, key.len, input, output)) {
            common.shared.GLOWCAP_OK => {},
            common.shared.GLOWCAP_ERR_WOULD_BLOCK => return if (op == 0) error.RecordUnloaded else error.WriteWouldBlock,
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
    // This fixed-resource projection has no collection submission API. A
    // future cursor projection must preserve bounded transaction-local walks.
    pub fn next(_: *Kv, _: []const u8, _: ?[]const u8) !?core.CollectionRow {
        return error.UnsupportedCollection;
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
        .recover => |batch| .{ .recover = try batch.resolve(try metadata(kv)) },
        .lookup => |lookup| .{ .lookup = try lookup.read(kv) },
        .read => |read| blk: {
            const meta = try metadata(kv);
            if (meta.store != read.ticket.store or meta.incarnation != read.ticket.incarnation or meta.revision != read.ticket.revision) return error.StaleCompletion;
            const bytes = (try kv.get(&read.id.key())) orelse break :blk .{ .read = .missing };
            if (bytes.len > read.buffer.len) return error.RecordTooLarge;
            @memcpy(read.buffer[0..bytes.len], bytes);
            break :blk .{ .read = .{ .found = .{ .length = bytes.len, .metadata = meta } } };
        },
    };
}
fn metadata(kv: *Kv) !core.Metadata {
    return core.Metadata.decode((try kv.get(core.metadata_key)) orelse return error.Corrupt);
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
    if (owner.startup_result != null) return error.Busy;
    const batch = if (recovery) try owner.value.recoveryBatch() else owner.startup_batch orelse blk: {
        const ticket = try owner.value.prepare();
        const batch = try owner.value.beginWrite(ticket);
        owner.startup_batch = batch;
        break :blk batch;
    };
    if (!recovery and owner.startup_evaluation == null) owner.startup_evaluation = core.Batch.Evaluation.init(&owner.startup_batch.?);
    const result: core.Resolution = if (recovery) try batch.resolve(try metadata(kv)) else .{ .committed = try owner.startup_evaluation.?.advance(kv) };
    owner.startup_result = result;
}
pub fn startupFinish(owner: *common.Store, recovery: bool, outcome: u32) !void {
    if (owner.attachments != 0) return error.Busy;
    if (outcome > 2 or (recovery and outcome == 2)) return error.InvalidArgument;
    if (recovery) {
        if (outcome != 0) {
            owner.startup_result = null;
            return error.RecoveryRequired;
        }
        const result = owner.startup_result orelse return error.WorkerNotRetired;
        try owner.value.resolve((try owner.value.recoveryBatch()).ticket, result);
        owner.startup_batch = null;
        owner.startup_evaluation = null;
        owner.startup_result = null;
        if (result == .unchanged) return error.WriteNotCommitted;
    } else {
        const batch = owner.startup_batch orelse return error.StaleCompletion;
        const result: core.Outcome = switch (outcome) {
            0 => .{ .committed = (owner.startup_result orelse return error.WorkerNotRetired).committed },
            1 => .{ .unchanged = error.WriteNotCommitted },
            2 => .unknown,
            else => unreachable,
        };
        defer {
            owner.startup_result = null;
            owner.startup_evaluation = null;
        }
        owner.value.completeWrite(batch.ticket, result) catch |err| {
            if (owner.value.phase != .uncertain) owner.startup_batch = null;
            return err;
        };
        if (owner.value.phase == .uncertain) return error.RecoveryRequired;
        owner.startup_batch = null;
        if (outcome == 1) return error.WriteNotCommitted;
    }
}
