//! Confirmation transfers one preallocated observer. No foreign callback runs.
const std = @import("std");
const common = @import("common.zig");
const attached = @import("attachment.zig");
const callbacks = @import("callbacks.zig");
const c = common.c;
const shared = common.shared;
const hosting = common.hosting;

/// The caller and kernel confirmation own independent references. Canceled
/// observers may outlive kernel custody. Their small metadata allocation and
/// attachment borrow remain until release. Kernel limits bound active intent,
/// not application-held inert handles.
pub const Control = struct {
    owner: *attached.Attachment,
    references: usize = 2,
    reservation: *hosting.ContinuationReservation = undefined,
    phase: union(enum) { pending, confirmed: *hosting.Continuation, active: *hosting.Continuation, canceled } = .pending,

    fn activate(context: ?*anyopaque, continuation: *hosting.Continuation) void {
        const self: *Control = @ptrCast(@alignCast(context.?));
        std.debug.assert(self.phase == .pending);
        self.phase = .{ .confirmed = continuation };
        self.release();
    }
    fn cancel(context: ?*anyopaque) void {
        const self: *Control = @ptrCast(@alignCast(context.?));
        std.debug.assert(self.phase == .pending);
        self.phase = .canceled;
        // Kernel cancellation still reads its State after this hook. This
        // releases only bridge custody; it never detaches the attachment.
        self.release();
    }
    fn release(self: *Control) void {
        std.debug.assert(self.references != 0);
        self.references -= 1;
        if (self.references != 0) return;
        switch (self.phase) {
            .confirmed, .active => |continuation| continuation.release(),
            else => {},
        }
        const owner = self.owner;
        std.debug.assert(owner.effect_observers != 0);
        owner.effect_observers -= 1;
        owner.store.allocator.destroy(self);
    }
    pub fn active(self: *Control) !*hosting.Continuation {
        return if (self.phase == .active) self.phase.active else error.WrongPhase;
    }
};

pub fn control(raw: anytype) !*Control {
    const self: *Control = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    try common.EvaluationGuard.check(self.owner.store);
    return self;
}

pub fn glowcap_loam_call_reserve_continuation_copying(raw: ?*c.GlowcapLoamCall, targets: ?[*]const shared.GlowcapReference, target_count: usize, out_reservation: ?*?*c.GlowcapLoamContinuationReservation, out_pending: ?*?*c.GlowcapLoamPendingContinuation) callconv(.c) i32 {
    shared.lastErrorClear();
    if (out_reservation) |out| out.* = null;
    if (out_pending) |out| out.* = null;
    const reservation = out_reservation orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const pending = out_pending orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const call: *callbacks.Call = @ptrCast(@alignCast(raw orelse return shared.GLOWCAP_ERR_NULL_POINTER));
    if (!call.active) return common.code(error.WrongPhase);
    reserve(call, targets, target_count, reservation, pending) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
fn reserve(call: *callbacks.Call, targets: ?[*]const shared.GlowcapReference, count: usize, out_reservation: *?*c.GlowcapLoamContinuationReservation, out_pending: *?*c.GlowcapLoamPendingContinuation) !void {
    const owner = call.attachment;
    if (count > owner.value.options.max_continuation_targets) return error.ContinuationCapacity;
    if (owner.effect_observers == std.math.maxInt(usize)) return error.ContinuationCapacity;
    const refs = try common.slice(shared.GlowcapReference, targets, count);
    const values = try call.content_call.allocator().alloc(common.driver.Capability, count);
    for (refs, values) |ref, *value| value.* = call.host.capabilityFromRaw(ref.id);
    const self = try owner.store.allocator.create(Control);
    errdefer owner.store.allocator.destroy(self);
    self.* = .{ .owner = owner };
    self.reservation = try call.content_call.reserveContinuationCopying(values, .{ .context = self, .activate = Control.activate, .cancel = Control.cancel });
    owner.effect_observers += 1;
    out_reservation.* = @ptrCast(self);
    out_pending.* = @ptrCast(self);
}

fn reference(_: void, value: common.driver.Value) !shared.GlowcapReference {
    return .{ .id = value.capability.raw() };
}
fn grant(self: *Control, capability: common.driver.Capability, out: *shared.GlowcapReference) !void {
    out.* = try self.owner.host_borrow.core().projectOwnedValue(.{ .capability = capability }, {}, reference);
}
pub fn glowcap_loam_continuation_reservation_source(raw: ?*c.GlowcapLoamContinuationReservation, out_reference: ?*shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = .{ .id = 0 };
    const self = control(raw) catch |err| return common.code(err);
    if (self.phase != .pending) return common.code(error.WrongPhase);
    grant(self, self.reservation.source(), out) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_continuation_reservation_target(raw: ?*c.GlowcapLoamContinuationReservation, index: usize, out_reference: ?*shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = .{ .id = 0 };
    const self = control(raw) catch |err| return common.code(err);
    if (self.phase != .pending) return common.code(error.WrongPhase);
    const target = self.reservation.target(index) catch |err| return common.code(err);
    grant(self, target, out) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

pub fn glowcap_loam_pending_continuation_take(raw: ?*c.GlowcapLoamPendingContinuation, out_continuation: ?*?*c.GlowcapLoamContinuation) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_continuation orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = null;
    const self = control(raw) catch |err| return common.code(err);
    self.owner.value.topLevel() catch |err| return common.code(err);
    switch (self.phase) {
        .pending => return common.code(error.Busy),
        .canceled => return common.code(error.WriteNotCommitted),
        .confirmed => |continuation| {
            self.phase = .{ .active = continuation };
            out.* = @ptrCast(self);
        },
        .active => return common.code(error.WrongPhase),
    }
    // Success consumes the Pending handle and transfers the identical observer.
    return shared.GLOWCAP_OK;
}
/// Report 1 once the commit is confirmed absent and 0 while it is pending or
/// confirmed. It reads only the observer, so it is valid during content
/// callbacks, where `take` refuses.
pub fn glowcap_loam_pending_continuation_absent(raw: ?*c.GlowcapLoamPendingContinuation, out_absent: ?*u32) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_absent orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = 0;
    const self = control(raw) catch |err| return common.code(err);
    switch (self.phase) {
        .pending, .confirmed => {},
        .canceled => out.* = 1,
        .active => return common.code(error.WrongPhase),
    }
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_pending_continuation_release(raw: ?*c.GlowcapLoamPendingContinuation) callconv(.c) i32 {
    shared.lastErrorClear();
    if (raw == null) return shared.GLOWCAP_OK;
    const self = control(raw) catch |err| return common.code(err);
    if (self.phase == .active) return common.code(error.WrongPhase);
    self.release();
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_continuation_release(raw: ?*c.GlowcapLoamContinuation) callconv(.c) i32 {
    shared.lastErrorClear();
    if (raw == null) return shared.GLOWCAP_OK;
    const self = control(raw) catch |err| return common.code(err);
    _ = self.active() catch |err| return common.code(err);
    self.release();
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_continuation_project(raw: ?*c.GlowcapLoamContinuation, index: usize, out_reference: ?*shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = .{ .id = 0 };
    const self = control(raw) catch |err| return common.code(err);
    self.owner.value.topLevel() catch |err| return common.code(err);
    const value = self.active() catch |err| return common.code(err);
    const capability = value.project(index) catch |err| return common.code(err);
    out.* = .{ .id = capability.raw() };
    return shared.GLOWCAP_OK;
}
