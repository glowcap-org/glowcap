//! Opaque operations keep authority selection and mutable Store access private.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const Descriptor = records.CapabilityRecord;
const Binding = @import("capabilities.zig").Binding;
const read_mod = @import("read.zig");
const Read = read_mod.Read;
const Append = @import("append.zig").Append;
const Load = @import("load.zig").Load;

pub const State = struct {
    binding: *Binding,
    snapshot: u64,
    incarnation: u64,
    capacity: usize,
    load: Load = .{},
    lease: ?loam.Lease = null,
    descriptor: Descriptor = undefined,
    read: ?Read = null,
    append: ?*Append = null,
    plan: ?core.GrantPlan = null,
    staged: bool = false,
    cancelled: bool = false,
    scratch: [core.max_scope_objects * @sizeOf(core.ResourceId)]u8 align(@alignOf(core.ResourceId)) = undefined,

    pub fn current(self: *State) !void {
        if (self.cancelled) return error.Cancelled;
        const store = self.binding.owner.store;
        if (store.phase == .uncertain) return error.RecoveryRequired;
        if (store.metadata.revision != self.snapshot or store.metadata.incarnation != self.incarnation) return error.RevisionConflict;
    }

    pub fn opened(self: *State) !void {
        try self.current();
        if (self.read == null) return error.RecordUnloaded;
        try self.read.?.opened();
        if (self.read.?.header.owner != self.descriptor.grant.owner) return error.ForeignOwner;
        var grants = try self.read.?.grantView();
        _ = try grants.get(self.descriptor.grant);
        const entry = (try self.read.?.binding(.{ .grant = self.descriptor.grant })).?;
        const found = try Read.rowFor(self.binding.owner.store, entry) orelse return error.InvalidRecord;
        if (!found.view.id.eql(self.descriptor.grant_object)) return error.InvalidRecord;
    }
};

pub fn begin(binding: *Binding, capacity: usize) !*Operation {
    const owner = binding.owner;
    if (owner.store.phase == .uncertain) return error.RecoveryRequired;
    if (capacity == 0 or capacity > owner.store.limits.max_leases -| 2) return error.InvalidLimits;
    if (owner.operations == owner.limits.max_operations) return error.OperationCapacity;
    try binding.retain();
    errdefer binding.release();
    const value = try owner.allocator.create(State);
    value.* = .{ .binding = binding, .snapshot = owner.store.metadata.revision, .incarnation = owner.store.metadata.incarnation, .capacity = capacity };
    owner.operations += 1;
    return @ptrCast(value);
}

pub fn state(operation: *Operation) *State {
    return @ptrCast(@alignCast(operation));
}

pub const Operation = opaque {
    pub const Description = struct { access: core.GrantView.Access, policy: core.Policy };

    /// Owned bounded values, valid as a snapshot only. Drive read demands and
    /// retry exactly as require; no owner/grant IDs or revisions are exposed.
    pub fn describe(self: *Operation, target: core.ResourceId) !Description {
        const value = state(self);
        if (value.binding.role != .use) return error.WrongRole;
        try value.opened();
        var grants = try value.read.?.grantView();
        var resources = try value.read.?.resourceView();
        return .{ .access = try grants.describe(&resources, &value.read.?.header.policy, value.descriptor.grant, target), .policy = value.read.?.header.policy };
    }

    pub fn advance(self: *Operation) !read_mod.Step {
        const value = state(self);
        try value.current();
        if (value.staged) return error.WrongPhase;
        const owner = value.binding.owner;
        if (value.lease == null) {
            const lease = switch (try value.load.acquire(owner.store, value.binding.object)) {
                .read => |request| return .{ .read = request },
                .waiting => return .waiting,
                .ready => |lease| lease,
            };
            errdefer owner.store.release(lease) catch unreachable;
            var fixed = std.heap.FixedBufferAllocator.init(&value.scratch);
            const descriptor = (try Descriptor.decodeOwned(fixed.allocator(), try owner.store.currentView(lease))).value;
            if (descriptor.role != value.binding.role) return error.WrongRole;
            value.read = try Read.init(owner.allocator, owner.store, descriptor.owner, value.capacity);
            value.descriptor = descriptor;
            value.lease = lease;
        }
        const result = try value.read.?.advance();
        if (result != .ready) return result;
        value.opened() catch |err| {
            if (err == error.RecordUnloaded) return value.read.?.advance();
            return err;
        };
        if (value.append) |append| return append.advance();
        return .ready;
    }

    pub fn completeRead(self: *Operation, ticket: loam.Ticket, result: loam.ReadResult) !void {
        const value = state(self);
        if (value.load.pending != null) return value.load.complete(value.binding.owner.store, ticket, result);
        if (value.read) |*read| if (read.load.pending != null) return read.completeRead(ticket, result);
        if (value.append) |append| if (append.load.pending != null) return append.completeRead(ticket, result);
        return error.StaleCompletion;
    }

    pub fn require(self: *Operation, target: core.ResourceId, requirement: core.Policy.Requirement) !void {
        const value = state(self);
        if (value.binding.role != .use) return error.WrongRole;
        try value.opened();
        var grants = try value.read.?.grantView();
        var resources = try value.read.?.resourceView();
        try grants.require(&resources, &value.read.?.header.policy, value.descriptor.grant, target, requirement);
    }

    /// Copies a permitted edit after all demanded records are loaded. False
    /// means unchanged. On RecordUnloaded, advance and retry with the same input.
    pub fn prepareEditCopying(self: *Operation, edit: core.Control.Edit) !bool {
        const value = state(self);
        if (value.binding.role != .control) return error.WrongRole;
        try value.opened();
        if (value.plan != null or value.staged) return error.WrongPhase;
        var resources = try value.read.?.resourceView();
        const command = try core.Control.command(&resources, &value.read.?.header.policy, value.descriptor.grant, value.descriptor.powers, edit);
        return prepare(value, command);
    }

    pub fn prepareDeriveCopying(self: *Operation, request: core.GrantLedger.Issue) !void {
        const value = state(self);
        if (value.binding.role != .use) return error.WrongRole;
        try value.opened();
        if (value.plan != null or value.staged) return error.WrongPhase;
        _ = try prepare(value, .{ .derive = .{ .parent = value.descriptor.grant, .request = request } });
        errdefer {
            value.plan.?.deinit(value.binding.owner.allocator);
            value.plan = null;
        }
        const append = try value.binding.owner.allocator.create(Append);
        errdefer value.binding.owner.allocator.destroy(append);
        append.* = try Append.init(&value.read.?, .grant);
        value.append = append;
    }

    pub fn cancel(self: *Operation) !void {
        const value = state(self);
        try value.load.cancel(value.binding.owner.store);
        if (value.read) |*read| try read.cancel();
        if (value.append) |append| try append.cancel();
        value.cancelled = true;
    }

    pub fn deinit(self: *Operation) !void {
        const value = state(self);
        if (value.load.pending != null) return error.Busy;
        if (value.read) |read| if (read.load.pending != null) return error.Busy;
        if (value.append) |append| if (append.load.pending != null) return error.Busy;
        const owner = value.binding.owner;
        if (value.append) |append| {
            try append.deinit();
            owner.allocator.destroy(append);
        }
        if (value.plan) |*plan| plan.deinit(owner.allocator);
        if (value.read) |*read| try read.deinit();
        if (value.lease) |lease| try owner.store.release(lease);
        value.binding.release();
        owner.operations -= 1;
        owner.allocator.destroy(value);
    }
};

fn prepare(value: *State, command: core.GrantPlan.Command) !bool {
    const read = &value.read.?;
    var grants = try read.grantView();
    var resources = try read.resourceView();
    const fresh: ?core.GrantId = if (read.header.next_grant < records.OwnerRecord.max_slots) .{ .owner = read.header.owner, .slot = @intCast(read.header.next_grant), .generation = 1 } else null;
    value.plan = try core.GrantPlan.prepareCopying(value.binding.owner.allocator, &grants, &resources, &read.header.policy, read.header.max_grant_children, fresh, command);
    return value.plan != null;
}
