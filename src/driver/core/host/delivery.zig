//! Host application delivery: send/tell admission, staging, and commit.
//!
//! This internal owner composes the existing capability routing, value
//! lowering, Vow, Served, and pump authorities into one delivery transaction.
//! It owns no duplicate state or walker; supported verbs remain Host aliases.

const std = @import("std");

const model = @import("model");
const actors = @import("actors");

const host_mod = @import("../host.zig");
const served_mod = @import("../served.zig");
const capability = @import("../capability.zig");
const capability_promise = @import("../capability_promise.zig");
const vows = @import("../vows.zig");
const value_mod = @import("../value.zig");
const lower = @import("capabilities/lower.zig");
const routing = @import("capabilities/routing.zig");
const host_pump = @import("pump.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;

/// Begin a caller-owned fetch-then-send chain as one session operation.
pub fn beginSendNamed(
    self: *Host,
    session: *HostSession,
    pending: *served_mod.Served.PendingSend,
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
    pending: *served_mod.Served.PendingSend,
    name: []const u8,
    msg: actors.Message,
    terminal: actors.Listener,
) !void {
    return beginDeliverNamed(self, session, pending, name, msg, terminal, true);
}

pub fn beginSendNamedValues(
    self: *Host,
    session: *HostSession,
    pending: *served_mod.Served.PendingSend,
    name: []const u8,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
    terminal: actors.Listener,
) !void {
    var prepared = try lower.prepareValues(self, session, arena, values);
    defer prepared.deinit();
    try beginSendNamed(self, session, pending, name, .{ .verb = verb, .args = prepared.values }, terminal);
    _ = prepared.commit();
}

pub fn beginTellNamedValues(
    self: *Host,
    session: *HostSession,
    pending: *served_mod.Served.PendingSend,
    name: []const u8,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
    terminal: actors.Listener,
) !void {
    var prepared = try lower.prepareValues(self, session, arena, values);
    defer prepared.deinit();
    try beginTellNamed(self, session, pending, name, .{ .verb = verb, .args = prepared.values }, terminal);
    _ = prepared.commit();
}

fn beginDeliverNamed(
    self: *Host,
    session: *HostSession,
    pending: *served_mod.Served.PendingSend,
    name: []const u8,
    msg: actors.Message,
    terminal: actors.Listener,
    tell_only: bool,
) !void {
    try self.admitApplicationOperation();
    try self.admitSessionOperation(session);
    try self.checkSession(session);
    try self.checkOutboundAdmission(session);
    const completion: served_mod.Served.PendingSend.Completion = .{
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
    return sendValuesWithProgress(self, session, target, verb, values, arena, true);
}

pub fn queueSendValues(
    self: *Host,
    session: *HostSession,
    target: capability.Ref,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
) !u64 {
    return sendValuesWithProgress(self, session, target, verb, values, arena, false);
}

fn sendValuesWithProgress(
    self: *Host,
    session: *HostSession,
    target: capability.Ref,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
    drive_now: bool,
) !u64 {
    try self.admitApplicationOperation();
    const resolved_target = self.capabilities.resolve(target) orelse return error.UnknownCapability;
    if (resolved_target == .deferred) {
        const promise = self.capability_promises.get(resolved_target.deferred) orelse
            return error.UnknownCapability;
        switch (promise.state) {
            .pending, .settling => {
                const id = try capability_promise.queueSendValues(
                    self,
                    resolved_target.deferred,
                    session,
                    verb,
                    values,
                );
                if (drive_now) host_pump.finishCommittedWork(self, session);
                return id;
            },
            .fulfilled, .broken => {},
        }
    }
    const routed = try routing.routeCapability(self, session, target, true);
    try self.checkOutboundAdmission(routed.session);
    const retained = try lower.retainValueCapabilities(self, arena, values);
    var retained_live = true;
    defer if (retained_live) lower.releaseUntransferredCapabilityRetains(self, retained);
    var prepared = try lower.prepareValues(self, routed.session, arena, values);
    defer prepared.deinit();
    const id = try commitRoutedSend(self, routed, .{
        .verb = verb,
        .args = prepared.values,
    }, drive_now, .{ .arena = arena, .retained = retained });
    _ = prepared.commit();
    lower.releaseUntransferredCapabilityRetains(self, retained);
    retained_live = false;
    return id;
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
    return commitRoutedSend(self, routed, msg, drive_now, null);
}

fn sendCapabilityWithProgress(
    self: *Host,
    session: *HostSession,
    target: capability.Ref,
    msg: actors.Message,
    drive_now: bool,
) !u64 {
    try self.admitApplicationOperation();
    const routed = try routing.routeCapability(self, session, target, true);
    try self.checkOutboundAdmission(routed.session);
    try routing.validateRoutedArguments(self, routed.session, msg.args);
    return commitRoutedSend(self, routed, msg, drive_now, null);
}

const OutboundStagingContext = struct {
    arena: std.mem.Allocator,
    retained: []lower.StagedCapabilityRetain,
};

fn commitRoutedSend(
    self: *Host,
    routed: routing.RoutedSend,
    msg: actors.Message,
    drive_now: bool,
    staging: ?OutboundStagingContext,
) !u64 {
    const location: actors.VowLocation = switch (routed.target) {
        .local => .local,
        .far => .far,
    };
    const reservation = try vows.reserveVow(self, routed.session, location, .plain);
    var reservation_live = true;
    errdefer if (reservation_live) vows.cancelVowReservation(self, reservation);
    const vow = if (staging) |context|
        try lower.servedSendWithStaging(
            self,
            routed.session,
            routed.target,
            msg,
            context.arena,
            context.retained,
        )
    else
        try routed.session.served.send(&self.vat, routed.target, msg);
    const id = vows.commitVow(self, routed.session, reservation, vow);
    reservation_live = false;
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
    return commitRoutedTell(self, routed, msg);
}

pub fn tellCapability(self: *Host, session: *HostSession, target: capability.Ref, msg: actors.Message) !void {
    try self.admitApplicationOperation();
    const routed = try routing.routeCapability(self, session, target, true);
    try self.checkOutboundAdmission(routed.session);
    try routing.validateRoutedArguments(self, routed.session, msg.args);
    return commitRoutedTell(self, routed, msg);
}

pub fn tellValues(
    self: *Host,
    session: *HostSession,
    target: capability.Ref,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
) !void {
    try self.admitApplicationOperation();
    const resolved_target = self.capabilities.resolve(target) orelse return error.UnknownCapability;
    if (resolved_target == .deferred) {
        const promise = self.capability_promises.get(resolved_target.deferred) orelse
            return error.UnknownCapability;
        switch (promise.state) {
            .pending, .settling => {
                try capability_promise.queueTellValues(
                    self,
                    resolved_target.deferred,
                    session,
                    verb,
                    values,
                );
                host_pump.finishCommittedWork(self, session);
                return;
            },
            .fulfilled, .broken => {},
        }
    }
    const routed = try routing.routeCapability(self, session, target, true);
    try self.checkOutboundAdmission(routed.session);
    const retained = try lower.retainValueCapabilities(self, arena, values);
    var retained_live = true;
    defer if (retained_live) lower.releaseUntransferredCapabilityRetains(self, retained);
    var prepared = try lower.prepareValues(self, routed.session, arena, values);
    defer prepared.deinit();
    try lower.servedTellWithStaging(
        self,
        routed.session,
        routed.target,
        .{ .verb = verb, .args = prepared.values },
        arena,
        retained,
    );
    _ = prepared.commit();
    lower.releaseUntransferredCapabilityRetains(self, retained);
    retained_live = false;
    self.node.exporterApplicationOwned(routed.session.peer_handle);
    try host_pump.dirtyThenPump(self, routed.session.peer_handle);
}

fn commitRoutedTell(self: *Host, routed: routing.RoutedSend, msg: actors.Message) !void {
    try routed.session.served.tell(&self.vat, routed.target, msg);
    self.node.exporterApplicationOwned(routed.session.peer_handle);
    try host_pump.dirtyThenPump(self, routed.session.peer_handle);
}
