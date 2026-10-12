//! Opaque operations keep authority selection and mutable Store access private.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const record = @import("record.zig");
const staging = @import("stage.zig");
const create = @import("capability_stage.zig");
const Descriptor = records.CapabilityRecord;
const Binding = @import("capabilities.zig").Binding;
const read_mod = @import("read.zig");
const Read = read_mod.Read;
const Append = @import("append.zig").Append;
const ResourceChange = @import("resource_change.zig").ResourceChange;
const Load = @import("load.zig").Load;

pub const State = struct {
    binding: *Binding,
    snapshot: u64,
    incarnation: u64,
    capacity: usize,
    load: Load = .{},
    lease: ?loam.Lease = null,
    descriptor: Descriptor = undefined,
    control_cursor: ?loam.ObjectId = null,
    control_ready: bool = false,
    control_live: bool = true,
    control_depth: usize = 0,
    read: ?Read = null,
    prepared: union(enum) {
        none,
        grant: struct { plan: core.GrantPlan, append: ?*Append = null, powers: ?@import("control_plan.zig").PowerCopy = null },
        resource: *ResourceChange,
        control: @import("control_plan.zig").Plan,
    } = .none,
    children: usize = 0,
    staged: bool = false,
    cancelled: bool = false,
    scratch: [records.CapabilityRecord.selection_bytes]u8 align(@alignOf(core.ResourceId)) = undefined,

    pub fn current(self: *State) !void {
        if (self.cancelled) return error.Cancelled;
        const store = self.binding.owner.store;
        if (store.phase == .uncertain) return error.RecoveryRequired;
        if (store.metadata.revision != self.snapshot or store.metadata.incarnation != self.incarnation) return error.RevisionConflict;
    }

    pub fn idle(self: *const State) !void {
        if (self.staged or self.prepared != .none) return error.WrongPhase;
    }

    pub fn unprepared(self: *const State) !void {
        try self.idle();
        if (self.children != 0) return error.Busy;
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
    pub const ControlDescription = @import("control_plan.zig").Description;
    pub const Description = struct { access: core.GrantView.Access, policy: core.Policy };
    /// Descriptive data from this operation's current resource view. The graph
    /// revision identifies the owner's resource snapshot, never grant admission.
    pub const BoundResource = struct { id: core.ResourceId, kind: core.KindId, object: loam.ObjectId, revision: core.Revision };

    /// Trusted embedding accounting data. The current grant and its parents
    /// already belong to this operation's validated working set. Copy their
    /// durable record names into caller storage. Names confer no authority.
    /// Hosting invokes this only after require, never as holder inspection.
    pub fn accountingPath(self: *Operation, buffer: []loam.ObjectId) ![]const loam.ObjectId {
        const value = state(self);
        if (value.binding.role != .use) return error.WrongRole;
        try value.opened();
        var grants = try value.read.?.grantView();
        var path = grants.ancestry(value.descriptor.grant);
        var count: usize = 0;
        while (try path.next()) |grant| {
            if (count == buffer.len) return error.DepthLimit;
            const binding = (try value.read.?.binding(.{ .grant = grant.id })).?;
            buffer[count] = binding.object orelse return error.InvalidRecord;
            count += 1;
        }
        return buffer[0..count];
    }

    /// Trusted embedding metadata before declaration, without scoped admission.
    /// Never expose this as holder-facing inspection. Describe owns that path.
    /// Hosting retains one scalar copy for its synchronous callbacks.
    /// The row is also needed by require. No additional lease or read spine exists.
    pub fn boundResource(self: *Operation, target: core.ResourceId) !BoundResource {
        const value = state(self);
        if (value.binding.role != .use) return error.WrongRole;
        try value.opened();
        var resources = try value.read.?.resourceView();
        const resource = try resources.get(target);
        const binding = (try value.read.?.binding(.{ .resource = target })).?;
        return .{ .id = resource.id, .kind = resource.kind, .object = binding.object orelse return error.InvalidRecord, .revision = resources.version.revision };
    }

    /// Owned bounded values, valid as a snapshot only. Drive read demands and
    /// retry exactly as require. No owner/grant IDs or revisions are exposed.
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
            const view = (try Read.rowForObject(owner.store, value.binding.object, lease)).view;
            if (view.schema == records.profile.terminal) {
                if ((try records.TerminalRecord.decode(view)).kind != .capability) return error.InvalidRecord;
                return error.CapabilityRetired;
            }
            var fixed = std.heap.FixedBufferAllocator.init(&value.scratch);
            const descriptor = (try Descriptor.decodeOwned(fixed.allocator(), view)).value;
            if (descriptor.role != value.binding.role) return error.WrongRole;
            value.read = try Read.init(owner.allocator, owner.store, descriptor.owner, value.capacity);
            value.descriptor = descriptor;
            value.control_cursor = descriptor.dependency;
            value.control_live = !descriptor.revoked;
            value.lease = lease;
        }
        for (0..128) |_| {
            const result = try value.read.?.advance();
            if (result != .ready) return result;
            value.opened() catch |err| {
                if (err == error.RecordUnloaded) continue;
                return err;
            };
            if (value.binding.role == .control and !value.control_ready) {
                const controls = try advanceControl(value);
                if (controls != .ready) return controls;
            }
            switch (value.prepared) {
                .grant => |grant| if (grant.append) |append| return append.advance(),
                .resource => |resource| return resource.advance(),
                else => {},
            }
            return .ready;
        }
        return .waiting;
    }

    pub fn completeRead(self: *Operation, ticket: loam.Ticket, result: loam.ReadResult) !void {
        const value = state(self);
        if (value.load.pending != null) return value.load.complete(value.binding.owner.store, ticket, result);
        if (value.read) |*read| if (read.hasPendingRead()) return read.completeRead(ticket, result);
        switch (value.prepared) {
            .grant => |grant| if (grant.append) |append| return append.completeRead(ticket, result),
            .resource => |resource| return resource.completeRead(ticket, result),
            else => {},
        }
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

    /// Admission covers the bound source and both placement parents. The
    /// resulting change remains private until staged in the owner's batch.
    pub fn prepareResourceCopying(self: *Operation, target: core.ResourceId, action: ResourceChange.Action, requirement: core.Policy.Requirement) !bool {
        const value = state(self);
        try value.current();
        try value.unprepared();
        try self.require(target, requirement);
        var resources = try value.read.?.resourceView();
        const source = try resources.get(target);
        if (source.parent) |parent| try self.require(parent, requirement);
        if (action == .move) if (action.move) |parent| try self.require(parent, requirement);
        const change = try value.binding.owner.allocator.create(ResourceChange);
        errdefer value.binding.owner.allocator.destroy(change);
        change.* = try ResourceChange.init(&value.read.?, target, action);
        value.prepared = .{ .resource = change };
        return change.changed;
    }

    pub fn stageResource(self: *Operation) !bool {
        return stagePreparedResource(state(self), false);
    }

    /// The returned cursor retains this operation. It exposes authorized IDs,
    /// not index offsets, owner revisions, hidden counts or serialized cursors.
    pub fn children(self: *Operation, parent: core.ResourceId, requirement: core.Policy.Requirement) !*@import("children.zig").Children {
        return @import("children.zig").create(self, parent, requirement);
    }

    /// Copies a permitted edit after all demanded records are loaded. False
    /// means unchanged. On RecordUnloaded, advance and retry with the same input.
    pub fn prepareEditCopying(self: *Operation, edit: core.Control.Edit) !bool {
        const value = state(self);
        if (value.binding.role != .control) return error.WrongRole;
        try requireControl(value);
        try value.unprepared();
        var resources = try value.read.?.resourceView();
        const command = try core.Control.command(&resources, &value.read.?.header.policy, value.descriptor.grant, value.descriptor.powers, edit);
        const plan = (try prepare(value, command)) orelse return false;
        value.prepared = .{ .grant = .{ .plan = plan } };
        return true;
    }

    pub fn prepareDeriveCopying(self: *Operation, request: core.GrantLedger.Issue) !void {
        const value = state(self);
        if (value.binding.role != .use) return error.WrongRole;
        try value.opened();
        try value.unprepared();
        var plan = (try prepare(value, .{ .derive = .{ .parent = value.descriptor.grant, .request = request } })) orelse return error.NoPreparedChange;
        errdefer plan.deinit(value.binding.owner.allocator);
        const append = try value.binding.owner.allocator.create(Append);
        errdefer value.binding.owner.allocator.destroy(append);
        append.* = try Append.init(&value.read.?, .grant);
        append.grant_parent = plan.delta.issue.parent;
        value.prepared = .{ .grant = .{ .plan = plan, .append = append } };
    }

    pub fn describeControl(self: *Operation) !@import("control_plan.zig").Description {
        return controlDescription(state(self));
    }

    pub fn requireManagement(self: *Operation) !void {
        try requireControl(state(self));
    }

    /// Issuance receipt recovery admits the exact use endpoint without using
    /// it. The hosting owner separately checks the held management control.
    pub fn requireRecovery(self: *Operation, target: core.ResourceId) !void {
        const value = state(self);
        if (value.binding.role != .use) return error.WrongRole;
        try value.opened();
        var grants = try value.read.?.grantView();
        var resources = try value.read.?.resourceView();
        try grants.requireRecovery(&resources, &value.read.?.header.policy, value.descriptor.grant, target);
    }

    /// Decode fresh management commands from held powers, even when use is
    /// revoked. The command owner decides terminal/no-op lifecycle semantics.
    pub fn controlPowers(self: *Operation) !core.Control.Powers {
        const value = state(self);
        try requireControl(value);
        return value.descriptor.powers;
    }

    pub fn prepareAttenuationCopying(self: *Operation, powers: core.Control.Powers) !void {
        try prepareAttenuation(state(self), powers);
    }

    pub fn prepareControlRevocation(self: *Operation) !bool {
        return prepareRevocation(state(self));
    }

    pub fn stageControlRevocation(self: *Operation) !bool {
        return stageRevocation(state(self));
    }

    pub fn prepareManagedDeriveCopying(self: *Operation, request: core.GrantLedger.Issue, powers: core.Control.Powers) !void {
        const value = state(self);
        try value.opened();
        try value.unprepared();
        var resources = try value.read.?.resourceView();
        try core.Control.validate(&resources, &value.read.?.header.policy, request.ceiling, powers);
        var owned = try @import("control_plan.zig").PowerCopy.init(value.binding.owner.allocator, powers);
        errdefer owned.deinit(value.binding.owner.allocator);
        try self.prepareDeriveCopying(request);
        value.prepared.grant.powers = owned;
    }

    /// Independently admit management issuance. The child's ancestry retains
    /// source use limits without requiring active use or delegation permission.
    pub fn prepareIssueCopying(self: *Operation, request: core.GrantLedger.Issue, powers: core.Control.Powers, expected: core.Revision) !void {
        const value = state(self);
        try requireControl(value);
        try value.unprepared();
        var grants = try value.read.?.grantView();
        if ((try grants.get(value.descriptor.grant)).revision != expected) return error.RevisionConflict;
        const ceiling = value.descriptor.powers.issue_ceiling orelse return error.Denied;
        if (!powers.empty() and !value.descriptor.powers.delegate_control) return error.Denied;
        var resources = try value.read.?.resourceView();
        try core.Control.validate(&resources, &value.read.?.header.policy, request.ceiling, powers);
        try core.Control.attenuate(&resources, &value.read.?.header.policy, value.descriptor.powers, powers);
        var owned = try @import("control_plan.zig").PowerCopy.init(value.binding.owner.allocator, powers);
        errdefer owned.deinit(value.binding.owner.allocator);
        var plan = (try prepare(value, .{ .issue_control = .{ .parent = value.descriptor.grant, .ceiling = ceiling, .request = request } })).?;
        errdefer plan.deinit(value.binding.owner.allocator);
        const append = try value.binding.owner.allocator.create(Append);
        errdefer value.binding.owner.allocator.destroy(append);
        append.* = try Append.init(&value.read.?, .grant);
        append.grant_parent = plan.delta.issue.parent;
        value.prepared = .{ .grant = .{ .plan = plan, .append = append, .powers = owned } };
    }

    /// Revision is checked before preparing even a no-op edit. Hosting checks
    /// a committed receipt first, so replay does not become a new stale edit.
    pub fn expectRevision(self: *Operation, expected: core.Revision) !void {
        const value = state(self);
        try requireControl(value);
        var grants = try value.read.?.grantView();
        if ((try grants.get(value.descriptor.grant)).revision != expected) return error.RevisionConflict;
    }

    /// Inspect is independent of editing, issuance and use. The shared branch
    /// check applies to the immutable grant ancestry, including paused use.
    pub fn inspectGrant(self: *Operation, target: ?core.GrantId) !core.GrantView.Record {
        const value = state(self);
        try requireControl(value);
        if (!value.descriptor.powers.inspect) return error.Denied;
        var grants = try value.read.?.grantView();
        if (try grants.effectiveStatus(value.descriptor.grant) == .revoked) return error.Revoked;
        const id = target orelse value.descriptor.grant;
        var path = grants.ancestry(id);
        while (try path.next()) |entry| {
            if (entry.id.eql(value.descriptor.grant)) return grants.get(id);
        }
        return error.OutOfScope;
    }

    /// An inspector can describe effective use at its immutable exact resource
    /// without acquiring a use endpoint. Collection and subtree policies need
    /// a target-specific inspection contract rather than a misleading aggregate.
    /// All values are scalar snapshots. The existing model owns every read.
    pub fn inspectFixedAccess(self: *Operation) !Description {
        const own = try self.inspectGrant(null);
        const target = switch (own.ceiling.scope) {
            .object => |id| id,
            .objects, .owned_subtree => return error.ExactResourceRequired,
        };
        const value = state(self);
        var grants = try value.read.?.grantView();
        var resources = try value.read.?.resourceView();
        return .{ .access = try grants.describe(&resources, &value.read.?.header.policy, value.descriptor.grant, target), .policy = value.read.?.header.policy };
    }

    pub fn cancel(self: *Operation) !void {
        const value = state(self);
        try value.load.cancel(value.binding.owner.store);
        if (value.read) |*read| try read.cancel();
        switch (value.prepared) {
            .grant => |grant| if (grant.append) |append| try append.cancel(),
            .resource => |resource| try resource.cancel(),
            else => {},
        }
        value.cancelled = true;
    }

    pub fn deinit(self: *Operation) !void {
        const value = state(self);
        if (value.load.pending != null) return error.Busy;
        if (value.read) |read| if (read.hasPendingRead()) return error.Busy;
        if (value.children != 0) return error.Busy;
        const owner = value.binding.owner;
        switch (value.prepared) {
            .resource => |resource| {
                try resource.deinit();
                owner.allocator.destroy(resource);
            },
            .grant => |*grant| {
                if (grant.append) |append| {
                    try append.deinit();
                    owner.allocator.destroy(append);
                }
                grant.plan.deinit(owner.allocator);
                if (grant.powers) |*powers| powers.deinit(owner.allocator);
            },
            .control => |*plan| plan.deinit(owner.allocator),
            .none => {},
        }
        if (value.read) |*read| try read.deinit();
        if (value.lease) |lease| try owner.store.release(lease);
        value.binding.release();
        owner.operations -= 1;
        owner.allocator.destroy(value);
    }
};

fn prepare(value: *State, command: core.GrantPlan.Command) !?core.GrantPlan {
    const read = &value.read.?;
    try read.prepareHistory();
    var grants = try read.grantView();
    var resources = try read.resourceView();
    const fresh: ?core.GrantId = if (read.header.next_grant < records.OwnerRecord.max_slots) .{ .owner = read.header.owner, .slot = @intCast(read.header.next_grant), .generation = 1 } else null;
    var plan = (try core.GrantPlan.prepareCopying(value.binding.owner.allocator, &grants, &resources, &read.header.policy, read.header.max_grant_children, fresh, command)) orelse return null;
    errdefer plan.deinit(value.binding.owner.allocator);
    if (plan.delta == .issue) try read.prepareIdentities(4);
    try staging.prepareGrant(read, &plan);
    return plan;
}

fn advanceControl(value: *State) !read_mod.Step {
    const store = value.binding.owner.store;
    if (value.control_depth == 0) {
        // The descriptor may have loaded before the owner's header. Establish
        // both from the current composed state before walking dependencies.
        var fixed = std.heap.FixedBufferAllocator.init(&value.scratch);
        const current = (try Descriptor.decodeOwned(fixed.allocator(), (try Read.rowForObject(store, value.binding.object, value.lease)).view)).value;
        if (current.role != value.binding.role or !current.owner.eql(value.descriptor.owner) or !current.grant.eql(value.descriptor.grant) or !current.grant_object.eql(value.descriptor.grant_object)) return error.InvalidRecord;
        value.descriptor = current;
        value.control_live = !current.revoked;
        value.control_cursor = current.dependency;
    }
    // The immutable dependency path is checked with one transient lease. Its
    // depth is independent of model residency and bounded at creation too.
    for (0..16) |_| {
        const object = value.control_cursor orelse {
            value.control_ready = true;
            return .ready;
        };
        if (value.control_depth >= value.read.?.header.max_grant_depth) return error.DepthLimit;
        const lease = switch (try value.load.acquire(store, object)) {
            .read => |read| return .{ .read = read },
            .waiting => return .waiting,
            .ready => |lease| lease,
        };
        defer store.release(lease) catch unreachable;
        const view = (try Read.rowForObject(store, object, lease)).view;
        if (view.schema == records.profile.terminal) {
            if ((try records.TerminalRecord.decode(view)).kind != .capability) return error.InvalidRecord;
            value.control_live = false;
            value.control_cursor = null;
            value.control_ready = true;
            return .ready;
        }
        var parent = try Descriptor.decodeOwned(value.binding.owner.allocator, (try Read.rowForObject(store, object, lease)).view);
        defer parent.deinit(value.binding.owner.allocator);
        if (parent.value.role != .control or !parent.value.owner.eql(value.descriptor.owner) or !parent.value.grant.eql(value.descriptor.grant)) return error.InvalidRecord;
        value.control_live = value.control_live and !parent.value.revoked;
        value.control_cursor = parent.value.dependency;
        value.control_depth += 1;
    }
    return .waiting;
}

fn requireControl(value: *State) !void {
    if (value.binding.role != .control) return error.WrongRole;
    try value.opened();
    if (!value.control_ready) return error.RecordUnloaded;
    if (!value.control_live) return error.ControlRevoked;
}

fn controlDescription(value: *State) !@import("control_plan.zig").Description {
    if (value.binding.role != .control) return error.WrongRole;
    try value.opened();
    if (!value.control_ready) return error.RecordUnloaded;
    var grants = try value.read.?.grantView();
    const status = try grants.effectiveStatus(value.descriptor.grant);
    const revision = (try grants.get(value.descriptor.grant)).revision;
    return .{ .available = value.control_live and status != .revoked, .grant_status = status, .powers = if (value.control_live and status != .revoked) value.descriptor.powers else .{}, .policy = value.read.?.header.policy, .revision = revision };
}

fn prepareAttenuation(value: *State, powers: core.Control.Powers) !void {
    try requireControl(value);
    try value.unprepared();
    if (value.control_depth == value.read.?.header.max_grant_depth) return error.DepthLimit;
    var grants = try value.read.?.grantView();
    if (try grants.effectiveStatus(value.descriptor.grant) == .revoked) return error.Revoked;
    if (!value.descriptor.powers.delegate_control) return error.Denied;
    var resources = try value.read.?.resourceView();
    try core.Control.attenuate(&resources, &value.read.?.header.policy, value.descriptor.powers, powers);
    try value.read.?.prepareIdentities(2);
    try value.read.?.prepareHistory();
    value.prepared = .{ .control = .{ .attenuation = try @import("control_plan.zig").PowerCopy.init(value.binding.owner.allocator, powers) } };
}

fn prepareRevocation(value: *State) !bool {
    if (value.binding.role != .control) return error.WrongRole;
    try value.opened();
    if (!value.control_ready) return error.RecordUnloaded;
    try value.unprepared();
    if (!value.descriptor.revoked) try value.read.?.prepareHistory();
    // A revoked descriptor may repeat its own terminal edit, but cannot recover
    // capabilities or perform grant mutations through a dead dependency.
    value.prepared = .{ .control = .{ .revocation = !value.descriptor.revoked } };
    return !value.descriptor.revoked;
}

fn stageRevocation(value: *State) !bool {
    try value.opened();
    if (value.staged or value.prepared != .control or value.prepared.control != .revocation) return error.WrongPhase;
    value.staged = true;
    if (!value.prepared.control.revocation) return false;
    var descriptor = value.descriptor;
    descriptor.revoked = true;
    const store = value.binding.owner.store;
    const old = try Read.rowForObject(store, value.binding.object, value.lease);
    errdefer if (store.phase == .staging) store.abort() catch unreachable;
    var edges: [3]loam.Edge = undefined;
    try record.putEncoded(store, old.view.id, records.profile.capability, descriptor, descriptor.edges(&edges), old.expected, old.view.rooted);
    try staging.controlChanged(&value.read.?, value.binding.object, .revoked);
    return true;
}

pub fn stageAttenuatedControl(value: *State, rooted: bool) !loam.ObjectId {
    try requireControl(value);
    if (value.staged or value.prepared != .control or value.prepared.control != .attenuation) return error.WrongPhase;
    var descriptor = value.descriptor;
    descriptor.powers = value.prepared.control.attenuation.powers;
    descriptor.dependency = value.binding.object;
    const id = try create.descriptor(&value.read.?, descriptor, rooted);
    try staging.controlChanged(&value.read.?, id, .attenuated);
    value.staged = true;
    return id;
}

pub fn stagePreparedResource(value: *State, content_changed: bool) !bool {
    try value.opened();
    if (value.staged) return error.WrongPhase;
    const resource = if (value.prepared == .resource) value.prepared.resource else return error.NoPreparedChange;
    resource.content_changed = content_changed;
    if (content_changed and !resource.changed) try staging.contentChanged(&value.read.?, resource.original.resource.id);
    const changed = if (content_changed and !resource.changed) false else try resource.stage();
    value.staged = true;
    return changed;
}
