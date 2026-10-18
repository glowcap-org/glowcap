//! Bounded privileged custody of durable managed references on one existing Store.
const std = @import("std");
const loam = @import("loam_core");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const Descriptor = records.CapabilityRecord;
const op = @import("capability_operation.zig");
const record = @import("record.zig");
const create = @import("capability_stage.zig");
const staging = @import("stage.zig");
const Read = @import("read.zig").Read;
const OwnerIndex = @import("owner_index.zig").OwnerIndex;

pub const Capabilities = struct {
    allocator: std.mem.Allocator,
    store: *loam.Store,
    limits: Limits,
    /// Resident owner headers and directory resolutions every operation's
    /// Read consults, heap-held because it is a few decoded headers wide.
    index: *OwnerIndex,
    references: usize = 0,
    operations: usize = 0,
    observations: usize = 0,
    pub const Limits = struct { max_references: usize = 128, max_operations: usize = 32 };
    pub const Staged = struct { change: core.GrantPlan.Change, derived_use: ?loam.ObjectId = null, derived_control: ?loam.ObjectId = null };

    /// Store and this owner stay at stable addresses until deinit succeeds.
    pub fn init(allocator: std.mem.Allocator, store: *loam.Store, limits: Limits) !Capabilities {
        if (limits.max_references == 0 or limits.max_operations == 0) return error.InvalidLimits;
        const index = try allocator.create(OwnerIndex);
        index.* = .{ .allocator = allocator };
        return .{ .allocator = allocator, .store = store, .limits = limits, .index = index };
    }

    pub fn deinit(self: *Capabilities) !void {
        if (self.references != 0 or self.operations != 0 or self.observations != 0) return error.Busy;
        self.index.deinit();
        self.allocator.destroy(self.index);
        self.* = undefined;
    }

    /// Privileged creation persists a descriptor. No reference escapes
    /// before commit. The caller roots it or retains it through content edges.
    pub fn stageUse(self: *Capabilities, read: *Read, grant: core.GrantId, rooting: record.Rooting) !loam.ObjectId {
        if (read.store != self.store) return error.ForeignStore;
        return create.create(read, grant, null, rooting);
    }

    pub fn stageControl(self: *Capabilities, read: *Read, grant: core.GrantId, powers: core.Control.Powers, rooting: record.Rooting) !loam.ObjectId {
        if (read.store != self.store) return error.ForeignStore;
        return create.create(read, grant, powers, rooting);
    }

    pub fn restoreUse(self: *Capabilities, lease: loam.Lease) !*Use {
        return @ptrCast(try self.restore(lease, .use));
    }

    pub fn restoreControl(self: *Capabilities, lease: loam.Lease) !*Control {
        return @ptrCast(try self.restore(lease, .control));
    }

    fn restore(self: *Capabilities, lease: loam.Lease, role: Descriptor.Role) !*Binding {
        const row = try self.store.currentView(lease);
        if (row.schema == records.profile.terminal) {
            if ((try records.TerminalRecord.decode(row)).kind != .capability) return error.InvalidRecord;
            return error.CapabilityRetired;
        }
        var scratch: [records.CapabilityRecord.selection_bytes]u8 align(@alignOf(core.ResourceId)) = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&scratch);
        var decoded: Descriptor = undefined;
        try decoded.decodeOwned(fixed.allocator(), row);
        if (decoded.role != role) return error.WrongRole;
        if (self.references == self.limits.max_references) return error.CapabilityCapacity;
        const retention = try self.store.retain(row.id);
        errdefer self.store.releaseRetention(retention) catch unreachable;
        const binding = try self.allocator.create(Binding);
        binding.* = .{ .owner = self, .object = row.id, .role = role, .retention = retention };
        self.references += 1;
        return binding;
    }

    /// Owner-only staging. The operation's role and bound grant admitted its
    /// plan. Derivation creates its use descriptor in the same content batch.
    pub fn stage(self: *Capabilities, operation: *Operation, rooting: record.Rooting) !Staged {
        const state = op.state(operation);
        if (state.binding.owner != self) return error.ForeignOperation;
        try state.opened();
        if (state.staged) return error.WrongPhase;
        const prepared = if (state.prepared == .grant) &state.prepared.grant else return error.NoPreparedChange;
        const plan = &prepared.plan;
        const result = try staging.grant(&state.read, plan, prepared.append);
        errdefer if (self.store.phase == .staging) self.store.abort() catch unreachable;
        var derived: ?loam.ObjectId = null;
        if (plan.delta == .issue) derived = try create.descriptor(&state.read, .{
            .owner = state.read.owner_object,
            .grant_object = result.object,
            .grant = result.change.grant,
            .role = .use,
        }, rooting);
        var control: ?loam.ObjectId = null;
        if (prepared.powers) |powers| control = try create.descriptor(&state.read, .{
            .owner = state.read.owner_object,
            .grant_object = result.object,
            .grant = result.change.grant,
            .role = .control,
            .powers = powers.powers,
        }, rooting);
        state.staged = true;
        return .{ .change = result.change, .derived_use = derived, .derived_control = control };
    }
    /// Stage the control prepared by `prepareAttenuationCopying`. The new
    /// descriptor retains its parent control and the same exact grant.
    pub fn stageAttenuatedControl(self: *Capabilities, operation: *Operation, rooting: record.Rooting) !loam.ObjectId {
        const state = op.state(operation);
        if (state.binding.owner != self) return error.ForeignOperation;
        return op.stageAttenuatedControl(state, rooting);
    }
};

/// The heap allocation each held reference makes. Raise it with the bytes named.
pub const binding_budget_bytes = 96;
comptime {
    if (@sizeOf(Binding) > binding_budget_bytes) @compileError(std.fmt.comptimePrint(
        "access.storage Binding is {d} bytes, over its {d}-byte budget. Raise the constant deliberately, with the bytes justified.",
        .{ @sizeOf(Binding), binding_budget_bytes },
    ));
}

pub const Binding = struct {
    owner: *Capabilities,
    object: loam.ObjectId,
    role: Descriptor.Role,
    retention: loam.Retention,
    aliases: u32 = 1,

    pub fn retain(self: *Binding) !void {
        if (self.aliases == std.math.maxInt(u32)) return error.CapabilityCapacity;
        self.aliases += 1;
    }
    pub fn release(self: *Binding) void {
        self.aliases -= 1;
        if (self.aliases != 0) return;
        const owner = self.owner;
        owner.store.releaseRetention(self.retention) catch unreachable;
        owner.references -= 1;
        owner.allocator.destroy(self);
    }
};

pub const Use = opaque {
    pub fn retain(self: *Use) !*Use {
        try useBinding(self).retain();
        return self;
    }
    pub fn release(self: *Use) void {
        useBinding(self).release();
    }
    pub fn begin(self: *Use, capacity: usize) !*Operation {
        return op.begin(useBinding(self), capacity);
    }
};

pub const Control = opaque {
    pub fn retain(self: *Control) !*Control {
        try controlBinding(self).retain();
        return self;
    }
    pub fn release(self: *Control) void {
        controlBinding(self).release();
    }
    pub fn begin(self: *Control, capacity: usize) !*Operation {
        return op.begin(controlBinding(self), capacity);
    }
};

pub const Operation = op.Operation;
fn useBinding(self: *Use) *Binding {
    return @ptrCast(@alignCast(self));
}
fn controlBinding(self: *Control) *Binding {
    return @ptrCast(@alignCast(self));
}
