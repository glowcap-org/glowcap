//! Private receipt observation borrows the original Call and projects once.
const std = @import("std");
const common = @import("common.zig");
const continuations = @import("continuations.zig");
const attached = @import("attachment.zig");
const c = common.c;
const shared = common.shared;
const driver = common.driver;
const hosting = common.hosting;

/// C child spines have an independently bounded representation. Byte leaves
/// borrow the core result. Successful projections grant independent occurrence
/// retains to the consumer, never to this scratch arena.
pub const Observer = struct {
    owner: *attached.Attachment,
    value: *hosting.Execution,
    projection: hosting.Call.Memory,

    pub fn projectionBytes(reply_bytes: usize) !usize {
        _ = try hosting.Execution.sizeBound(reply_bytes);
        // A copied reply charges every descendant Value and struct entry to
        // its fixed buffer. The root Value is inline in Call.State.
        const values = try std.math.add(usize, reply_bytes / @sizeOf(driver.Value), 1);
        const Entry = std.meta.Elem(@FieldType(driver.Value, "struct"));
        const entries = reply_bytes / @sizeOf(Entry);
        const bound = try common.host.embedding.valueProjectionBound(hosting.references.AllocationBound, values, entries);
        return bound.physicalBytes();
    }
    pub fn callerBytes(reply_bytes: usize) !usize {
        const core = try hosting.Execution.sizeBound(reply_bytes);
        return std.math.add(usize, try std.math.add(usize, core, @sizeOf(Observer)), try projectionBytes(reply_bytes));
    }
    fn release(self: *Observer) void {
        const owner = self.owner;
        self.projection.deinit();
        self.value.deinit();
        std.debug.assert(owner.effect_observers != 0);
        owner.effect_observers -= 1;
        owner.store.allocator.destroy(self);
    }
};
fn observer(raw: ?*c.GlowcapLoamEffectExecution) !*Observer {
    const self: *Observer = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    try common.EvaluationGuard.check(self.owner.store);
    return self;
}
fn capability(host: *driver.Host, reference: shared.GlowcapReference) !driver.Capability {
    return host.capabilityFromRaw(reference.id);
}
fn execute(control: *continuations.Control, index: usize, verb: []const u8, args: ?[*]const shared.GlowcapArgument, args_len: usize, reply_bytes: usize) !*Observer {
    const owner = control.owner;
    const core = try control.active();
    try owner.value.topLevel();
    const projection_bytes = try Observer.projectionBytes(reply_bytes);
    if (owner.effect_observers == std.math.maxInt(usize)) return error.ContinuationCapacity;
    const gpa = owner.store.allocator;
    const self = try gpa.create(Observer);
    errdefer gpa.destroy(self);
    // C-to-Value child spines borrow leaves only through constructor return.
    // The admitted owning Call copies them into the existing Host queue once.
    var input = std.heap.ArenaAllocator.init(gpa);
    defer input.deinit();
    const values = try shared.valuesFromCWith(driver.Value, anyerror, owner.host_borrow.core(), capability, input.allocator(), args, args_len, 0, false);
    const call = try core.execute(gpa, index, verb, values, reply_bytes);
    self.owner = owner;
    self.value = call;
    self.projection.init(gpa, projection_bytes);
    owner.effect_observers += 1;
    return self;
}

pub fn glowcap_loam_continuation_execute_copying(raw: ?*c.GlowcapLoamContinuation, index: usize, verb: ?[*]const u8, verb_len: usize, args: ?[*]const shared.GlowcapArgument, args_len: usize, reply_bytes: usize, out_execution: ?*?*c.GlowcapLoamEffectExecution) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_execution orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = null;
    const control = continuations.control(raw) catch |err| return common.code(err);
    const name = shared.sliceFromC(verb, verb_len) catch |err| return common.code(err);
    const value = execute(control, index, name, args, args_len, reply_bytes) catch |err| return common.code(err);
    out.* = @ptrCast(value);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_effect_execution_result(raw: ?*c.GlowcapLoamEffectExecution, out_result: ?*c.GlowcapLoamEffectResult) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_result orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = std.mem.zeroes(c.GlowcapLoamEffectResult);
    const self = observer(raw) catch |err| return common.code(err);
    self.owner.value.topLevel() catch |err| return common.code(err);
    self.projection.resetWorking();
    const result = self.value.result();
    switch (result) {
        .pending => {},
        .ready => |value| {
            const projected = self.owner.host_borrow.core().projectOwnedValue(value, self.projection.working.allocator(), common.host.embedding.valueToC) catch |err| {
                self.projection.resetWorking();
                return common.code(err);
            };
            out.state = 1;
            out.value = projected;
        },
        .unsent, .unknown => |failure| {
            out.state = if (result == .unsent) 2 else 3;
            out.result = switch (failure.kind) {
                .broken => shared.GLOWCAP_ERR_BROKEN,
                .closed => shared.GLOWCAP_ERR_CLOSED,
            };
            out.message = if (failure.message.len == 0) null else failure.message.ptr;
            out.message_len = failure.message.len;
        },
    }
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_effect_execution_release(raw: ?*c.GlowcapLoamEffectExecution) callconv(.c) i32 {
    shared.lastErrorClear();
    if (raw == null) return shared.GLOWCAP_OK;
    const self = observer(raw) catch |err| return common.code(err);
    if (self.owner.host_borrow.core().withinCallback()) return common.code(error.Busy);
    self.owner.value.topLevel() catch |err| return common.code(err);
    self.release();
    return shared.GLOWCAP_OK;
}
