//! Real receipt callbacks, commit recovery and independent C effect observers.
const std = @import("std");
const c = @import("c_abi_loam");
const n = @import("c_abi_loam_lmdb");
const h = @import("c_abi_host");
const shared = @import("c_abi_shared");
const driver = @import("driver_core");

pub const methods = [_]c.GlowcapLoamMethod{
    .{ .verb = "get", .verb_len = 3, .retry = 0 },
    .{ .verb = "reserve", .verb_len = 7, .retry = 2 },
    .{ .verb = "refuse", .verb_len = 6, .retry = 2 },
};
pub const Probe = struct {
    host: *h.GlowcapHost,
    source: shared.GlowcapReference = .{ .id = 0 },
    target: shared.GlowcapReference = .{ .id = 0 },
    pending: ?*c.GlowcapLoamPendingContinuation = null,
    callback_count: usize = 0,
    target_count: usize = 0,
    owner: ?*c.embedding.Attachment = null,
    faults_checked: bool = false,

    pub fn invoke(context: ?*anyopaque, call: *c.GlowcapLoamCall, input: *const c.GlowcapLoamInvocation) callconv(.c) i32 {
        const self: *Probe = @ptrCast(@alignCast(context.?));
        const verb = input.verb.?[0..input.verb_len];
        if (!std.mem.eql(u8, verb, "get")) {
            if (!self.faults_checked) {
                checkReservationRefusals(self, call) catch return shared.GLOWCAP_ERR_INTERNAL;
                self.faults_checked = true;
            }
            self.callback_count += 1;
            var reservation: ?*c.GlowcapLoamContinuationReservation = null;
            const result = c.glowcap_loam_call_reserve_continuation_copying(call, @as([*]const shared.GlowcapReference, @ptrCast(&self.target)), 1, &reservation, &self.pending);
            if (result != shared.GLOWCAP_OK) return result;
            var source: shared.GlowcapReference = undefined;
            var target: shared.GlowcapReference = undefined;
            std.debug.assert(c.glowcap_loam_continuation_reservation_source(reservation, &source) == shared.GLOWCAP_OK);
            std.debug.assert(c.glowcap_loam_continuation_reservation_target(reservation, 0, &target) == shared.GLOWCAP_OK);
            std.debug.assert(source.id == self.source.id and target.id == self.target.id);
            std.debug.assert(h.glowcap_host_ref_release(self.host, &source, 1) == shared.GLOWCAP_OK);
            std.debug.assert(h.glowcap_host_ref_release(self.host, &target, 1) == shared.GLOWCAP_OK);
            if (std.mem.eql(u8, verb, "refuse")) return c.GLOWCAP_LOAM_ERR_APPLICATION;
            const replaced = c.glowcap_loam_call_replace_copying(call, "reserved", 8);
            if (replaced != shared.GLOWCAP_OK) return replaced;
        }
        var reply = std.mem.zeroes(shared.GlowcapArgument);
        reply.kind = shared.GLOWCAP_ARG_VOID;
        return c.glowcap_loam_call_reply(call, &reply);
    }
};
const Target = struct {
    probe: *Probe,
    source: driver.Capability,
    pub fn handle(self: *Target, turn: *driver.HostTurn, _: []const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        self.probe.target_count += 1;
        const nested = try turn.turn.arena.alloc(driver.Value, 2);
        nested[0] = .{ .capability = self.source };
        nested[1] = .{ .string = "exact" };
        const result = try turn.turn.arena.alloc(driver.Value, 2);
        result[0] = .{ .capability = self.source };
        result[1] = .{ .list = nested };
        return .{ .list = result };
    }
};

fn progress(owner: *c.embedding.Attachment, backend: *n.GlowcapLoamLmdb, lose_ack: *bool) !void {
    _ = try owner.host_borrow.core().vat.driveIngressBudgeted(.local, 64);
    try owner.value.advance();
    const raw: *c.GlowcapLoamAttachment = @ptrCast(owner);
    var work: ?*c.GlowcapLoamWork = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_next_work(raw, 0, &work));
    while (work != null) {
        var kind: u32 = 0;
        try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_kind(work, &kind));
        try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_lmdb_work_run(backend, work));
        const uncertain = lose_ack.* and kind == 1;
        if (uncertain) {
            lose_ack.* = false;
            try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_report_unknown(work));
        }
        var completed: u32 = 0;
        try std.testing.expectEqual(if (uncertain) c.GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED else shared.GLOWCAP_OK, c.glowcap_loam_work_complete(work, &completed));
        try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_work_release(work));
        if (uncertain) return;
        try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_next_work(raw, 0, &work));
    }
}
fn query(raw: ?*c.GlowcapLoamEffectExecution) !c.GlowcapLoamEffectResult {
    var value: c.GlowcapLoamEffectResult = undefined;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_effect_execution_result(raw, &value));
    return value;
}
fn references(value: c.GlowcapLoamEffectResult, expected: u64) ![2]shared.GlowcapReference {
    try std.testing.expectEqual(@as(u32, 1), value.state);
    try std.testing.expectEqual(shared.GLOWCAP_ARG_LIST, value.value.kind);
    const first = value.value.items.?[0].reference;
    const second = value.value.items.?[1].items.?[0].reference;
    try std.testing.expectEqual(expected, first.id);
    try std.testing.expectEqual(expected, second.id);
    return .{ first, second };
}

pub fn check(owner: *c.embedding.Attachment, backend: *n.GlowcapLoamLmdb, probe: *Probe) !void {
    probe.owner = owner;
    try sizing();
    const host = owner.host_borrow.core();
    const source = host.capabilityFromRaw(probe.source.id);
    const actor = try host.vat.spawn(driver.Hosting(Target), .{ .inner = .{ .probe = probe, .source = source } });
    const target = try host.liftLocalActor(actor);
    defer host.releaseCapabilityTerminal(target, null);
    probe.target = .{ .id = target.raw() };
    const receipt = try host.callLocalCapability(std.testing.allocator, source, "mutate", &.{ .{ .integer = 1 }, .{ .string = "reserve" } }, 4096);
    var receipt_owned = true;
    defer if (receipt_owned) receipt.deinit();
    var lose_ack = true;
    for (0..64) |_| {
        try progress(owner, backend, &lose_ack);
        if (owner.store.value.phase == .uncertain) break;
    }
    try std.testing.expectEqual(@as(usize, 1), probe.callback_count);
    try std.testing.expectEqual(.uncertain, owner.store.value.phase);
    var continuation: ?*c.GlowcapLoamContinuation = null;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, c.glowcap_loam_pending_continuation_take(probe.pending, &continuation));
    var absent: u32 = 1;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_pending_continuation_absent(probe.pending, &absent));
    try std.testing.expectEqual(@as(u32, 0), absent);
    try std.testing.expect(continuation == null);
    try std.testing.expectEqual(@as(usize, 0), probe.target_count);
    // Submitted storage custody survives abandonment of the original observer.
    receipt.deinit();
    receipt_owned = false;
    for (0..64) |_| {
        try progress(owner, backend, &lose_ack);
        const code = c.glowcap_loam_pending_continuation_take(probe.pending, &continuation);
        if (code == shared.GLOWCAP_OK) break;
        try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, code);
    }
    try std.testing.expect(continuation != null);
    probe.pending = null;
    var execution: ?*c.GlowcapLoamEffectExecution = null;
    try executionRefusals(owner, backend, continuation.?, probe);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_continuation_execute_copying(continuation, 0, "get", 3, null, 0, 4096, &execution));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_continuation_release(continuation));
    for (0..64) |_| {
        try progress(owner, backend, &lose_ack);
        const value = try query(execution);
        if (value.state != 0) {
            if (value.state == 1) for (try references(value, probe.source.id)) |ref| {
                try std.testing.expectEqual(shared.GLOWCAP_OK, h.glowcap_host_ref_release(probe.host, &ref, 1));
            };
            break;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), probe.target_count);
    try std.testing.expectEqual(@as(usize, 0), owner.value.continuations);
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, c.glowcap_loam_attachment_release(@ptrCast(owner)));
    // The initial poll above grants independent refs too; release them before
    // isolating projection refusal. Repeated projections are distinct ownership.
    const initial = try references(try query(execution), probe.source.id);
    for (initial) |ref| try std.testing.expectEqual(shared.GLOWCAP_OK, h.glowcap_host_ref_release(probe.host, &ref, 1));
    try projectionRefusal(owner, execution.?, probe);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_effect_execution_release(execution));
    try std.testing.expectEqual(@as(usize, 0), owner.effect_observers);

    // A Loam target defers its actual owning reply through another retained
    // operation. It must obey the same result contract as an immediate actor.
    probe.target = probe.source;
    const nested = try host.callLocalCapability(std.testing.allocator, source, "mutate", &.{ .{ .integer = 2 }, .{ .string = "reserve" } }, 4096);
    defer nested.deinit();
    for (0..64) |_| {
        try progress(owner, backend, &lose_ack);
        if (nested.result() != .pending) break;
    }
    try std.testing.expect(nested.result() == .ready);
    // A confirmed observer is not absent, and the query leaves it for take.
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_pending_continuation_absent(probe.pending, &absent));
    try std.testing.expectEqual(@as(u32, 0), absent);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_pending_continuation_take(probe.pending, &continuation));
    probe.pending = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_continuation_execute_copying(continuation, 0, "get", 3, null, 0, 4096, &execution));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_continuation_release(continuation));
    for (0..64) |_| {
        try progress(owner, backend, &lose_ack);
        if ((try query(execution)).state != 0) break;
    }
    const result = try query(execution);
    try std.testing.expectEqual(@as(u32, 1), result.state);
    try std.testing.expectEqual(shared.GLOWCAP_ARG_VOID, result.value.kind);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_effect_execution_release(execution));

    const refused = try host.callLocalCapability(std.testing.allocator, source, "mutate", &.{ .{ .integer = 3 }, .{ .string = "refuse" } }, 4096);
    defer refused.deinit();
    for (0..64) |_| {
        try progress(owner, backend, &lose_ack);
        if (refused.result() != .pending) break;
    }
    try std.testing.expect(refused.result() == .failed);
    try std.testing.expectEqual(c.GLOWCAP_LOAM_ERR_UNCHANGED, c.glowcap_loam_pending_continuation_take(probe.pending, &continuation));
    try std.testing.expect(continuation == null);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_pending_continuation_absent(probe.pending, &absent));
    try std.testing.expectEqual(@as(u32, 1), absent);
    try std.testing.expectEqual(@as(usize, 0), owner.value.continuations);
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, c.glowcap_loam_attachment_release(@ptrCast(owner)));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_pending_continuation_release(probe.pending));
    probe.pending = null;
    try std.testing.expectEqual(@as(usize, 0), owner.effect_observers);

    const abandoned = try host.callLocalCapability(std.testing.allocator, source, "mutate", &.{ .{ .integer = 3 }, .{ .string = "reserve" } }, 4096);
    defer abandoned.deinit();
    lose_ack = true;
    for (0..64) |_| {
        try progress(owner, backend, &lose_ack);
        if (owner.store.value.phase == .uncertain) break;
    }
    try std.testing.expectEqual(.uncertain, owner.store.value.phase);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_pending_continuation_release(probe.pending));
    probe.pending = null;
    try std.testing.expectEqual(@as(usize, 1), owner.effect_observers);
    for (0..64) |_| {
        try progress(owner, backend, &lose_ack);
        if (abandoned.result() != .pending) break;
    }
    try std.testing.expect(abandoned.result() == .ready);
    try std.testing.expectEqual(@as(usize, 0), owner.value.continuations);
    try std.testing.expectEqual(@as(usize, 0), owner.effect_observers);
}

fn projectionRefusal(owner: *c.embedding.Attachment, raw: *c.GlowcapLoamEffectExecution, probe: *Probe) !void {
    const Observer = c.embedding.effect_execution.Observer;
    const observed: *Observer = @ptrCast(@alignCast(raw));
    observed.projection.resetWorking();
    var failing = std.testing.FailingAllocator.init(owner.store.allocator, .{ .fail_index = 0 });
    observed.projection.backing.child = failing.allocator();
    defer {
        observed.projection.resetWorking();
        observed.projection.backing.child = owner.store.allocator;
    }
    const host = owner.host_borrow.core();
    const source = host.capabilityFromRaw(probe.source.id);
    const baseline = host.capabilities.retainCount(source).?;
    var value: c.GlowcapLoamEffectResult = undefined;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INTERNAL, c.glowcap_loam_effect_execution_result(raw, &value));
    try std.testing.expectEqualDeep(std.mem.zeroes(c.GlowcapLoamEffectResult), value);
    try std.testing.expectEqual(baseline, host.capabilities.retainCount(source).?);
    failing.fail_index = std.math.maxInt(usize);
    const first = try references(try query(raw), probe.source.id);
    const second = try references(try query(raw), probe.source.id);
    var bound: c.GlowcapLoamEffectExecutionBounds = undefined;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_effect_execution_result_size_bound(4096, &bound));
    try std.testing.expect(observed.projection.backing.used + @sizeOf(Observer) + try driver.Host.Call.sizeBound(4096) <= bound.caller_bytes);
    try std.testing.expectEqual(baseline + 4, host.capabilities.retainCount(source).?);
    for (first ++ second) |ref| try std.testing.expectEqual(shared.GLOWCAP_OK, h.glowcap_host_ref_release(probe.host, &ref, 1));
    try std.testing.expectEqual(baseline, host.capabilities.retainCount(source).?);
    try std.testing.expectEqual(@as(usize, 1), probe.target_count);
}

fn sizing() !void {
    var shape = std.mem.zeroes(c.GlowcapLoamValueBounds);
    var bounds: c.GlowcapLoamContinuationBounds = undefined;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_continuation_size_bound(&shape, 0, 0, &bounds));
    const empty = bounds;
    shape.values = 3;
    shape.capabilities = 2;
    shape.bytes = 128;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_continuation_size_bound(&shape, 8, 3, &bounds));
    try std.testing.expect(bounds.custody_bytes > empty.custody_bytes and bounds.call_bytes > empty.call_bytes);
    try std.testing.expectEqual(empty.observer_bytes, bounds.observer_bytes);
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(usize, 40), bounds.observer_bytes);
    for (0..3) |which| {
        var overflow = shape;
        if (which == 0) overflow.values = std.math.maxInt(usize);
        try std.testing.expect(c.glowcap_loam_continuation_size_bound(&overflow, if (which == 1) std.math.maxInt(usize) else 8, if (which == 2) std.math.maxInt(usize) else 3, &bounds) != shared.GLOWCAP_OK);
        try std.testing.expectEqualDeep(std.mem.zeroes(c.GlowcapLoamContinuationBounds), bounds);
    }
    var reply: c.GlowcapLoamEffectExecutionBounds = undefined;
    for ([_]usize{ 0, std.math.maxInt(usize) }) |bytes| {
        try std.testing.expect(c.glowcap_loam_effect_execution_result_size_bound(bytes, &reply) != shared.GLOWCAP_OK);
        try std.testing.expectEqualDeep(std.mem.zeroes(c.GlowcapLoamEffectExecutionBounds), reply);
    }
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_effect_execution_result_size_bound(4096, &reply));
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 80), @sizeOf(c.embedding.effect_execution.Observer));
        try std.testing.expectEqual(@as(usize, 32), reply.host_dispatch_bytes);
    }
}

fn checkReservationRefusals(probe: *Probe, call: *c.GlowcapLoamCall) !void {
    const owner = probe.owner.?;
    const backing = owner.store.allocator;
    const core_backing = owner.value.allocator;
    defer {
        owner.store.allocator = backing;
        owner.value.allocator = core_backing;
    }
    const host = owner.host_borrow.core();
    const source = host.capabilityFromRaw(probe.source.id);
    const count = host.capabilities.retainCount(source).?;
    for (0..3) |index| {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = index });
        owner.store.allocator = failing.allocator();
        owner.value.allocator = failing.allocator();
        var reservation: ?*c.GlowcapLoamContinuationReservation = undefined;
        var pending: ?*c.GlowcapLoamPendingContinuation = undefined;
        try std.testing.expectEqual(shared.GLOWCAP_ERR_INTERNAL, c.glowcap_loam_call_reserve_continuation_copying(call, @ptrCast(&probe.target), 1, &reservation, &pending));
        try std.testing.expect(reservation == null and pending == null);
        try std.testing.expectEqual(@as(usize, 0), owner.effect_observers);
        try std.testing.expectEqual(@as(usize, 0), owner.value.continuations);
        try std.testing.expectEqual(count, host.capabilities.retainCount(source).?);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

fn executionRefusals(owner: *c.embedding.Attachment, backend: *n.GlowcapLoamLmdb, continuation: *c.GlowcapLoamContinuation, probe: *Probe) !void {
    const backing = owner.store.allocator;
    for (0..3) |index| {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = index });
        owner.store.allocator = failing.allocator();
        var execution: ?*c.GlowcapLoamEffectExecution = undefined;
        const result = c.glowcap_loam_continuation_execute_copying(continuation, 0, "get", 3, null, 0, 4096, &execution);
        owner.store.allocator = backing;
        try std.testing.expectEqual(shared.GLOWCAP_ERR_INTERNAL, result);
        try std.testing.expect(execution == null);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        var lose_ack = false;
        try progress(owner, backend, &lose_ack);
        try std.testing.expectEqual(@as(usize, 0), probe.target_count);
        try std.testing.expectEqual(@as(usize, 1), owner.effect_observers);
        try std.testing.expectEqual(@as(usize, 1), owner.value.continuations);
    }
}
