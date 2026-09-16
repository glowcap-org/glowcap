//! Prepared grant deltas reserve current graph scope and own every commit input.
//! Storage adapters receive a typed write and report its exact outcome. No I/O,
//! queue, serialized storage format, or application content store lives here.

const std = @import("std");
const types = @import("grant_types.zig");
const identity = @import("identity.zig");
const Graph = @import("graph.zig").Graph;
const Ledger = @import("grants.zig").GrantLedger;
const Entry = types.Entry;
const planner = @import("grant_plan.zig");
const Plan = planner.GrantPlan;
const GrantId = identity.GrantId;
const Error = types.Error;

pub const Command = Plan.Command;

/// Identifies one immutable prepared payload. This is a local storage token,
/// not an admission credential, remote retry key, or durable recovery record.
pub const Ticket = struct {
    owner: identity.OwnerId,
    sequence: u64,
    base: types.Version,
};
pub const Outcome = enum { committed, unchanged, unknown };
pub const Resolution = enum { committed, unchanged };
pub const Completion = union(enum) { committed: types.Change, unchanged, recovery_required };

/// All record changes in this write must persist atomically. Selections borrow
/// ledger-owned memory until a known outcome or cancellation retires the write.
/// These records describe proposed data; they grant no publishable authority.
pub const Write = struct {
    ticket: Ticket,
    version: types.Version,
    record: types.Record,
    parent_record: ?types.Record,
};

pub const Pending = struct {
    ticket: Ticket,
    reservation: Graph.Reservation,
    phase: enum { prepared, writing, uncertain } = .prepared,
    plan: Plan,
};

pub fn prepareCopying(self: *Ledger, base: types.Version, command: Command) Error!?Ticket {
    if (self.pending) |pending| return if (pending.phase == .uncertain) error.RecoveryRequired else error.Busy;
    if (!std.meta.eql(base, self.version())) return error.RevisionConflict;
    if (self.graph.reservation != null) return error.Busy;
    var grants = self.readView();
    var resources = self.graph.readView();
    const fresh: ?GrantId = if (self.used == self.limits.capacity) null else .{ .owner = self.graph.owner, .slot = self.used, .generation = 1 };
    var plan = try Plan.prepareCopying(self.allocator, &grants, &resources, &self.policy, self.limits.max_children, fresh, command) orelse return null;
    errdefer plan.deinit(self.allocator);
    if (self.transaction_sequence == std.math.maxInt(u64)) return error.TransactionExhausted;
    const reservation = try self.graph.reserve(base.resources);
    self.transaction_sequence += 1;
    const ticket: Ticket = .{ .owner = self.graph.owner, .sequence = self.transaction_sequence, .base = base };
    self.pending = .{ .ticket = ticket, .reservation = reservation, .plan = plan };
    return ticket;
}

pub fn beginWrite(self: *Ledger, ticket: Ticket) Error!Write {
    const pending = try matching(self, ticket);
    if (pending.phase != .prepared) return error.WrongPhase;
    try checkReservation(self, pending);
    const write = try writeView(self, pending);
    pending.phase = .writing;
    return write;
}

pub fn finishWrite(self: *Ledger, ticket: Ticket, outcome: Outcome) Error!Completion {
    const pending = try matching(self, ticket);
    if (pending.phase != .writing) return error.WrongPhase;
    try checkReservation(self, pending);
    return switch (outcome) {
        .committed => .{ .committed = commit(self, pending) },
        .unchanged => blk: {
            discard(self, pending);
            break :blk .unchanged;
        },
        .unknown => blk: {
            pending.phase = .uncertain;
            break :blk .recovery_required;
        },
    };
}

pub fn resolveWrite(self: *Ledger, ticket: Ticket, resolution: Resolution) Error!Completion {
    const pending = try matching(self, ticket);
    if (pending.phase != .uncertain) return error.WrongPhase;
    try checkReservation(self, pending);
    return switch (resolution) {
        .committed => .{ .committed = commit(self, pending) },
        .unchanged => blk: {
            discard(self, pending);
            break :blk .unchanged;
        },
    };
}

pub fn cancel(self: *Ledger, ticket: Ticket) Error!void {
    const pending = try matching(self, ticket);
    if (pending.phase != .prepared) return error.Busy;
    try checkReservation(self, pending);
    discard(self, pending);
}

pub fn commitVolatile(self: *Ledger, ticket: Ticket) Error!types.Change {
    const pending = try matching(self, ticket);
    if (pending.phase != .prepared) return error.WrongPhase;
    try checkReservation(self, pending);
    return commit(self, pending);
}

fn matching(self: *Ledger, ticket: Ticket) Error!*Pending {
    const pending = if (self.pending) |*value| value else return error.InvalidTransaction;
    if (!std.meta.eql(ticket, pending.ticket)) return error.InvalidTransaction;
    return pending;
}

fn checkReservation(self: *Ledger, pending: *Pending) Error!void {
    if (!std.meta.eql(self.version(), pending.ticket.base) or !self.graph.ownsReservation(pending.reservation)) {
        // A trusted embedding bypassed the reservation. Do not adopt a storage
        // result against different state or make further protected admissions.
        pending.phase = .uncertain;
        return error.RecoveryRequired;
    }
}

fn writeView(self: *const Ledger, pending: *const Pending) Error!Write {
    var grants = self.readView();
    const changes = try pending.plan.changes(&grants);
    return .{ .ticket = pending.ticket, .version = changes.event.version, .record = changes.record, .parent_record = changes.parent_record };
}

fn commit(self: *Ledger, pending: *Pending) types.Change {
    const plan = &pending.plan;
    const next: identity.Revision = @fromBackingInt(@backingInt(pending.ticket.base.grants) + 1);
    switch (plan.delta) {
        .issue => |entry| {
            self.entries[plan.grant.slot] = entry;
            self.used += 1;
            if (entry.parent) |parent| {
                self.entries[parent.slot].child_count += 1;
                self.entries[parent.slot].revision = next;
            }
        },
        .policy => |replacement| {
            self.entries[plan.grant.slot].configured.deinit(self.allocator);
            self.entries[plan.grant.slot].configured = replacement;
        },
        .status => |status| self.entries[plan.grant.slot].status = status,
    }
    self.entries[plan.grant.slot].revision = next;
    self.current_revision = next;
    const change: types.Change = .{ .version = self.version(), .grant = plan.grant, .kind = plan.kind };
    // Reservation was checked immediately before this synchronous commit.
    self.graph.release(pending.reservation) catch unreachable;
    self.pending = null;
    return change;
}

fn discard(self: *Ledger, pending: *Pending) void {
    pending.plan.deinit(self.allocator);
    self.graph.release(pending.reservation) catch unreachable;
    self.pending = null;
}

pub fn lookup(self: *const Ledger, id: GrantId) Error!*const Entry {
    if (id.owner != self.graph.owner) return error.ForeignOwner;
    if (id.slot >= self.used) return error.UnknownGrant;
    if (id.generation != 1) return error.Gone;
    return &self.entries[id.slot];
}

pub const recordOf = planner.recordOf;
