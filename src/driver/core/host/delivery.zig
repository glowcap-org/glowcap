//! Host application delivery: send/tell admission, staging, and commit.
//!
//! This internal owner composes the existing capability routing, value
//! lowering, Vow, Served, and pump authorities into one delivery transaction.
//! It owns no duplicate state or walker. Supported verbs remain Host aliases.

const std = @import("std");

const model = @import("model");
const actors = @import("actors");

const host_mod = @import("../host.zig");
const pending_send = @import("../pending_send.zig");
const capability = @import("../capability.zig");
const capability_promise = @import("../capability_promise.zig");
const vow_settlement = @import("../vows/settlement.zig");
const vows = @import("../vows.zig");
const value_mod = @import("../value.zig");
const value_views = @import("../value_views.zig");
const lower = @import("capabilities/lower.zig");
const routing = @import("capabilities/routing.zig");
const host_pump = @import("pump.zig");
const WorkAdmission = @import("admission.zig").WorkAdmission;

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;

/// Begin a caller-owned fetch-then-send chain as one session operation.
pub fn beginSendNamed(
    self: *Host,
    session: *HostSession,
    pending: *pending_send.PendingSend,
    name: []const u8,
    msg: actors.Message,
    terminal: actors.Listener,
) !void {
    return beginDeliverNamed(self, session, pending, name, msg, terminal, false);
}

/// The fire-and-forget arm of the same admitted fetch/deliver transaction.
pub fn beginTellNamed(
    self: *Host,
    session: *HostSession,
    pending: *pending_send.PendingSend,
    name: []const u8,
    msg: actors.Message,
    terminal: actors.Listener,
) !void {
    return beginDeliverNamed(self, session, pending, name, msg, terminal, true);
}

pub fn beginSendNamedValues(
    self: *Host,
    session: *HostSession,
    pending: *pending_send.PendingSend,
    name: []const u8,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
    terminal: actors.Listener,
) !void {
    var prepared = try lower.prepareValues(self, session, arena, values);
    defer prepared.deinit();
    try lower.holdForTurn(self, &prepared);
    try beginSendNamed(self, session, pending, name, .{ .verb = verb, .args = prepared.values }, terminal);
    _ = prepared.commit();
}

pub fn beginTellNamedValues(
    self: *Host,
    session: *HostSession,
    pending: *pending_send.PendingSend,
    name: []const u8,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
    terminal: actors.Listener,
) !void {
    var prepared = try lower.prepareValues(self, session, arena, values);
    defer prepared.deinit();
    try lower.holdForTurn(self, &prepared);
    try beginTellNamed(self, session, pending, name, .{ .verb = verb, .args = prepared.values }, terminal);
    _ = prepared.commit();
}

fn beginDeliverNamed(
    self: *Host,
    session: *HostSession,
    pending: *pending_send.PendingSend,
    name: []const u8,
    msg: actors.Message,
    terminal: actors.Listener,
    tell_only: bool,
) !void {
    try self.admitApplicationOperation();
    try self.admitSessionOperation(session);
    try self.checkSession(session);
    try self.checkOutboundAdmission(session);
    const completion: pending_send.PendingSend.Completion = .{
        .ctx = session,
        .func = finishPendingSend,
    };
    if (tell_only)
        try session.served.beginTellNamedCompleting(&self.vat, pending, name, msg, terminal, completion)
    else
        try session.served.beginSendNamedCompleting(&self.vat, pending, name, msg, terminal, completion);
    self.beginSessionOperation(session);
    self.node.exporterApplicationOwned(session.peer_handle);
    host_pump.markDirty(self, session.peer_handle);
}

fn finishPendingSend(ctx: ?*anyopaque) void {
    const session: *HostSession = @ptrCast(@alignCast(ctx.?));
    session.host.finishSessionOperation(session);
}

pub fn send(self: *Host, session: *HostSession, target: model.Reference, msg: actors.Message) !u64 {
    return sendWithProgress(self, session, target, msg, true);
}

pub fn queueSend(self: *Host, session: *HostSession, target: model.Reference, msg: actors.Message) !u64 {
    return sendWithProgress(self, session, target, msg, false);
}

pub fn sendCapability(
    self: *Host,
    session: *HostSession,
    target: capability.Ref,
    msg: actors.Message,
) !u64 {
    return sendCapabilityWithProgress(self, session, target, msg, true);
}

pub fn queueSendCapability(
    self: *Host,
    session: *HostSession,
    target: capability.Ref,
    msg: actors.Message,
) !u64 {
    return sendCapabilityWithProgress(self, session, target, msg, false);
}

pub fn sendValues(
    self: *Host,
    session: *HostSession,
    target: capability.Ref,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
) !u64 {
    return sendValuesWithProgress(self, session, target, verb, values, arena, true, null, .application);
}

/// An application need not choose a transport session for held authority. Local
/// targets use the owning queue. Foreign targets use their actual home and the
/// same routed delivery as an explicitly selected session.
pub fn sendApplicationValues(self: *Host, target: capability.Ref, verb: []const u8, values: []const value_mod.Value, arena: std.mem.Allocator) !u64 {
    try self.refuseReentry();
    const selected = try routing.applicationTarget(self, target);
    if (selected.session == null) {
        var lease = try self.admitPendingWork();
        defer lease.complete();
        return self.sendLocalValues(&lease, selected.ref, verb, values);
    }
    return sendValues(self, selected.session.?, selected.ref, verb, values, arena);
}

/// Notification admission uses the actual capability home and no answer vow.
pub fn tellApplicationValues(self: *Host, target: capability.Ref, verb: []const u8, values: []const value_mod.Value, arena: std.mem.Allocator) !void {
    try self.refuseReentry();
    const selected = try routing.applicationTarget(self, target);
    if (selected.session == null) {
        var lease = try self.admitPendingWork();
        defer lease.complete();
        return @import("local_delivery.zig").tellLocal(self, &lease, selected.ref, verb, values);
    }
    return tellValues(self, selected.session.?, selected.ref, verb, values, arena);
}

pub fn queueSendValues(
    self: *Host,
    session: *HostSession,
    target: capability.Ref,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
) !u64 {
    return sendValuesWithProgress(self, session, target, verb, values, arena, false, null, .application);
}

pub fn sendValuesAdmitted(self: *Host, session: *HostSession, target: capability.Ref, verb: []const u8, values: []const value_mod.Value, arena: std.mem.Allocator, admission: WorkAdmission) !u64 {
    return sendValuesWithProgress(self, session, target, verb, values, arena, false, null, admission);
}

/// Both recipients reserve answer-release custody before the actual send.
pub const Observation = union(enum) {
    call: *@import("owned_call.zig").Call,
    listener: actors.Listener,
};

pub fn sendObservedValuesAdmitted(self: *Host, session: *HostSession, target: capability.Ref, verb: []const u8, values: []const value_mod.Value, arena: std.mem.Allocator, observer: Observation, admission: WorkAdmission) !u64 {
    return sendValuesWithProgress(self, session, target, verb, values, arena, false, observer, admission);
}

fn sendValuesWithProgress(
    self: *Host,
    session: *HostSession,
    target: capability.Ref,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
    drive_now: bool,
    observer: ?Observation,
    admission: WorkAdmission,
) !u64 {
    try admission.check(self);
    if (try unsettledPromiseOf(self, target)) |promise_id| {
        if (observer != null) return error.NotResolved;
        const id = try capability_promise.queueSendValues(self, promise_id, session, verb, values);
        if (drive_now) host_pump.finishCommittedWork(self, session);
        return id;
    }
    const routed = try routing.routeCapability(self, session, target, .object_only);
    try self.checkOutboundAdmission(routed.session);
    if (freightOf(routed, verb, values)) |freight|
        return commitRoutedSend(self, routed, freight, drive_now, null, observer);
    var prepared = try lower.prepareValues(self, routed.session, arena, values);
    defer prepared.deinit();
    try lower.holdForTurn(self, &prepared);
    const id = try commitRoutedSend(self, routed, .{
        .verb = verb,
        .args = .fromOwnedSlice(prepared.values),
    }, drive_now, &prepared, observer);
    _ = prepared.commit();
    return id;
}

/// The unsettled promise `target` stands for, when a send to it queues on
/// the promise instead of routing to an exporter. A settled promise and a
/// direct target route.
fn unsettledPromiseOf(self: *Host, target: capability.Ref) !?capability.PromiseId {
    const resolved = self.capabilities.resolve(target) orelse return error.UnknownCapability;
    if (resolved != .deferred) return null;
    const promise = self.capability_promises.get(resolved.deferred) orelse return error.UnknownCapability;
    return switch (promise.state) {
        .pending, .settling => resolved.deferred,
        .fulfilled, .broken => null,
    };
}

/// A far send of values that carry no capability leaves as freight: the
/// values back a view sequence the engine certifies, then encodes without
/// lowering an owned tree (ADR-0246). A local target
/// and a tree with a capability take the owned path, which lowers each
/// capability under the session.
fn freightOf(routed: routing.RoutedSend, verb: []const u8, values: []const value_mod.Value) ?actors.Delivery {
    if (routed.target != .far or value_views.carriesCapability(values)) return null;
    return .{ .verb = verb, .args = value_views.args(values), .reference_slots = 0 };
}

fn sendWithProgress(
    self: *Host,
    session: *HostSession,
    target: model.Reference,
    msg: actors.Message,
    drive_now: bool,
) !u64 {
    try self.admitApplicationOperation();
    const routed = try routing.routeSend(self, session, target, msg.args);
    try self.checkOutboundAdmission(routed.session);
    return commitRoutedSend(self, routed, msg.delivery(), drive_now, null, null);
}

fn sendCapabilityWithProgress(
    self: *Host,
    session: *HostSession,
    target: capability.Ref,
    msg: actors.Message,
    drive_now: bool,
) !u64 {
    try self.admitApplicationOperation();
    const routed = try routing.routeCapability(self, session, target, .object_only);
    try self.checkOutboundAdmission(routed.session);
    try routing.validateRoutedArguments(self, routed.session, msg.args);
    return commitRoutedSend(self, routed, msg.delivery(), drive_now, null, null);
}

/// Commit a routed send. `staging` is the lease window of lowered values,
/// and the Port decides how any other delivery leaves.
fn commitRoutedSend(
    self: *Host,
    routed: routing.RoutedSend,
    delivery: actors.Delivery,
    drive_now: bool,
    staging: ?*lower.PreparedValues,
    observer: ?Observation,
) !u64 {
    const location: actors.VowLocation = switch (routed.target) {
        .local => .local,
        .far => .far,
    };
    const answer_release: vow_settlement.AnswerRelease = switch (location) {
        .local => .none,
        .far => .peer_visible,
    };
    var reservation = try vows.reserveVow(self, routed.session, location, .plain, answer_release);
    defer reservation.deinit();
    if (observer) |recipient| switch (recipient) {
        .call => |owned| try @import("owned_call.zig").observe(owned, routed.session, reservation.getRow()),
        .listener => |listener| {
            if (answer_release == .peer_visible)
                reservation.getRow().observer_release = try routed.session.served.port.peer.reserveAnswerRelease();
            reservation.getRow().inner = listener;
        },
    };
    const vow = if (staging) |prepared|
        try lower.servedSendWithStaging(self, routed.session, routed.target, .{ .verb = delivery.verb, .args = prepared.values }, prepared)
    else
        try routed.session.served.sendDelivery(&self.vat, routed.target, delivery);
    const id = reservation.commit(vow);
    self.node.exporterApplicationOwned(routed.session.peer_handle);
    if (drive_now)
        host_pump.finishCommittedVow(self, routed.session)
    else
        host_pump.markDirty(self, routed.session.peer_handle);
    return id;
}

pub fn tell(self: *Host, session: *HostSession, target: model.Reference, msg: actors.Message) !void {
    try self.admitApplicationOperation();
    const routed = try routing.routeSend(self, session, target, msg.args);
    try self.checkOutboundAdmission(routed.session);
    return commitRoutedTell(self, routed, msg.delivery());
}

pub fn tellCapability(self: *Host, session: *HostSession, target: capability.Ref, msg: actors.Message) !void {
    try self.admitApplicationOperation();
    const routed = try routing.routeCapability(self, session, target, .object_only);
    try self.checkOutboundAdmission(routed.session);
    try routing.validateRoutedArguments(self, routed.session, msg.args);
    return commitRoutedTell(self, routed, msg.delivery());
}

pub fn tellValues(
    self: *Host,
    session: *HostSession,
    target: capability.Ref,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
) !void {
    return tellValuesAdmitted(self, session, target, verb, values, arena, .application);
}

pub fn tellValuesAdmitted(self: *Host, session: *HostSession, target: capability.Ref, verb: []const u8, values: []const value_mod.Value, arena: std.mem.Allocator, admission: WorkAdmission) !void {
    try admission.check(self);
    if (try unsettledPromiseOf(self, target)) |promise_id| {
        try capability_promise.queueTellValues(self, promise_id, session, verb, values);
        host_pump.finishCommittedWork(self, session);
        return;
    }
    const routed = try routing.routeCapability(self, session, target, .object_only);
    try self.checkOutboundAdmission(routed.session);
    if (freightOf(routed, verb, values)) |freight| return commitRoutedTell(self, routed, freight);
    var prepared = try lower.prepareValues(self, routed.session, arena, values);
    defer prepared.deinit();
    try lower.holdForTurn(self, &prepared);
    try lower.servedTellWithStaging(
        self,
        routed.session,
        routed.target,
        .{ .verb = verb, .args = prepared.values },
        &prepared,
    );
    _ = prepared.commit();
    self.node.exporterApplicationOwned(routed.session.peer_handle);
    try host_pump.dirtyThenPump(self, routed.session.peer_handle);
}

fn commitRoutedTell(self: *Host, routed: routing.RoutedSend, delivery: actors.Delivery) !void {
    try routed.session.served.tellDelivery(&self.vat, routed.target, delivery);
    self.node.exporterApplicationOwned(routed.session.peer_handle);
    try host_pump.dirtyThenPump(self, routed.session.peer_handle);
}
