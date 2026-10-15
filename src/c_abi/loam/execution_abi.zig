//! The embedding supplies transaction-local KV access and terminal outcomes.
const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");
const works = @import("work.zig");
const attached = @import("attachment.zig");
const c = common.c;
const shared = common.shared;

/// Derive a maximum encoded record from the shared envelope writer without
/// allocation or storage access. This is sizing, not schema admission.
pub fn glowcap_loam_schema_size_bound(raw: ?*const c.GlowcapLoamSchema, out_bytes: ?*usize) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_bytes orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = 0;
    const schema = raw orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const declaration: common.core.Schema = .{ .id = schema.id, .version = schema.version, .max_payload = schema.max_payload, .max_edges = schema.max_edges };
    out.* = declaration.encodedSizeBound() catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

pub fn glowcap_loam_validate_configuration(schemas: ?[*]const c.GlowcapLoamSchema, schema_count: usize, limits: ?*const c.GlowcapLoamLimits) callconv(.c) i32 {
    shared.lastErrorClear();
    const declarations = common.slice(c.GlowcapLoamSchema, schemas, schema_count) catch |err| return common.code(err);
    const bounds = limits orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    common.Store.validateConfiguration(declarations, bounds.*) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

pub fn glowcap_loam_metadata_claim(identity: ?[*]const u8, create: u32, previous: ?[*]const u8, previous_len: usize, out_metadata: ?[*]u8, out_len: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    const id = identity orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const out = out_metadata orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const mode = std.enums.fromInt(common.core.OpenMode, create) orelse return common.code(error.InvalidArgument);
    if (out_len != common.core.Metadata.encoded_size) return common.code(error.InvalidArgument);
    const old = common.slice(u8, previous, previous_len) catch |err| return common.code(err);
    const metadata = execution.claim(id[0..16], mode, if (previous == null) null else old) catch |err| return common.code(err);
    @memcpy(out[0..out_len], &metadata.encode());
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_store_plan(raw: ?*c.GlowcapLoamStore, recovery: u32, callback: ?execution.GlowcapLoamKvFn, context: ?*anyopaque) callconv(.c) i32 {
    shared.lastErrorClear();
    if (recovery > 1) return common.code(error.InvalidArgument);
    const owner = common.store(raw) catch |err| return common.code(err);
    var kv: execution.Kv = .{ .callback = callback orelse return shared.GLOWCAP_ERR_NULL_POINTER, .context = context };
    var guard: common.EvaluationGuard = .{};
    guard.enter(owner) catch |err| return common.code(err);
    defer guard.leave();
    execution.startupPlan(owner, recovery == 1, &kv) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
/// Evaluate one bounded collection batch in the adapter's atomic transaction.
/// It runs at most `work_limit` steps plus the steps that finish its open unit,
/// and `glowcap_loam_store_finish(raw, 0, outcome)` retires it. An attachment
/// refuses it.
pub fn glowcap_loam_store_collect_plan(raw: ?*c.GlowcapLoamStore, work_limit: usize, callback: ?execution.GlowcapLoamKvFn, context: ?*anyopaque) callconv(.c) i32 {
    shared.lastErrorClear();
    const owner = common.store(raw) catch |err| return common.code(err);
    var kv: execution.Kv = .{ .callback = callback orelse return shared.GLOWCAP_ERR_NULL_POINTER, .context = context };
    var guard: common.EvaluationGuard = .{};
    guard.enter(owner) catch |err| return common.code(err);
    defer guard.leave();
    execution.collectPlan(owner, work_limit, &kv) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
/// Report with 1 that a collection cycle is in progress, and 0 when none is.
pub fn glowcap_loam_store_collecting(raw: ?*c.GlowcapLoamStore, out_collecting: ?*u32) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_collecting orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = 0;
    const owner = common.store(raw) catch |err| return common.code(err);
    out.* = @intFromBool(owner.value.metadata.collection.phase != .idle);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_store_finish(raw: ?*c.GlowcapLoamStore, recovery: u32, outcome: u32) callconv(.c) i32 {
    shared.lastErrorClear();
    if (recovery > 1) return common.code(error.InvalidArgument);
    const owner = common.store(raw) catch |err| return common.code(err);
    execution.startupFinish(owner, recovery == 1, outcome) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_work_kind(raw: ?*c.GlowcapLoamWork, out_kind: ?*u32) callconv(.c) i32 {
    shared.lastErrorClear();
    const work = works.from(raw) catch |err| return common.code(err);
    const out = out_kind orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = switch (work.slot.request) {
        .read => 0,
        .write => 1,
        .lookup => 2,
        .recover => 3,
    };
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_work_plan(raw: ?*c.GlowcapLoamWork, callback: ?execution.GlowcapLoamKvFn, context: ?*anyopaque) callconv(.c) i32 {
    shared.lastErrorClear();
    const work = works.from(raw) catch |err| return common.code(err);
    if (work.slot.completed or work.slot.result != null or work.planned != null) return common.code(error.StaleCompletion);
    var kv: execution.Kv = .{ .callback = callback orelse return shared.GLOWCAP_ERR_NULL_POINTER, .context = context };
    var guard: common.EvaluationGuard = .{};
    guard.enter(work.owner.store) catch |err| return common.code(err);
    defer guard.leave();
    const result = execution.plan(work.slot.request, if (work.evaluation) |*cursor| cursor else null, &kv) catch |err| return common.code(err);
    work.planned = result;
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_work_finish(raw: ?*c.GlowcapLoamWork, outcome: u32) callconv(.c) i32 {
    shared.lastErrorClear();
    const work = works.from(raw) catch |err| return common.code(err);
    if (work.slot.completed or work.slot.result != null) return common.code(error.StaleCompletion);
    const result = execution.finish(work.slot.request, work.planned, outcome) catch |err| return common.code(err);
    work.slot.result = result;
    work.planned = null;
    return shared.GLOWCAP_OK;
}
/// Restore only from a validated snapshot owned by this adapter. The caller
/// retains the returned occurrence until its read transaction has completed.
pub fn glowcap_loam_restore_plan(raw: ?*c.GlowcapLoamAttachment, object: ?*const c.GlowcapLoamObject, callback: ?execution.GlowcapLoamKvFn, context: ?*anyopaque, out_ref: ?*shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    const owner = attached.attachment(raw) catch |err| return common.code(err);
    const source = object orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const out = out_ref orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    owner.value.topLevel() catch |err| return common.code(err);
    var guard: common.EvaluationGuard = .{};
    guard.enter(owner.store) catch |err| return common.code(err);
    defer guard.leave();
    const id = common.object(source.*) catch |err| return common.code(err);
    var kv: execution.Kv = .{ .callback = callback orelse return shared.GLOWCAP_ERR_NULL_POINTER, .context = context };
    // Load all transaction inputs before acquiring a pending core read. A
    // missing callback row must not leave a core ticket without an executor.
    const meta_bytes = (kv.get(common.core.metadata_key) catch |err| return common.code(err)) orelse return common.code(error.Corrupt);
    const metadata = common.core.Metadata.decode(meta_bytes) catch |err| return common.code(err);
    if (!std.meta.eql(metadata, owner.store.value.metadata)) return common.code(error.StaleCompletion);
    const bytes = (kv.get(&id.key()) catch |err| return common.code(err)) orelse return common.code(error.Gone);
    const lease = switch (owner.store.value.acquire(id) catch |err| return common.code(err)) {
        .ready => |value| value,
        .read => |request| blk: {
            if (bytes.len > request.buffer.len) {
                owner.store.value.completeRead(request.ticket, .{ .failed = error.RecordTooLarge }) catch |err| return common.code(err);
                return common.code(error.RecordTooLarge);
            }
            @memcpy(request.buffer[0..bytes.len], bytes);
            owner.store.value.completeRead(request.ticket, .{ .found = .{ .length = bytes.len, .metadata = metadata } }) catch |err| return common.code(err);
            break :blk (owner.store.value.acquire(id) catch |err| return common.code(err)).ready;
        },
    };
    defer owner.store.value.release(lease) catch unreachable;
    const reference = owner.value.restore(lease) catch |err| return common.code(err);
    out.* = .{ .id = reference.raw() };
    return shared.GLOWCAP_OK;
}
