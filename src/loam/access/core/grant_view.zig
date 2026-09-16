//! Current grant records over a bounded synchronous source. An unloaded
//! ancestor produces a read demand, never an optimistic authority verdict.
const std = @import("std");
const identity = @import("identity.zig");
const types = @import("grant_types.zig");
const ResourceView = @import("resource_view.zig").ResourceView;
const Policy = @import("policy.zig").Policy;
const Terms = @import("terms.zig").Terms;

pub const GrantView = struct {
    version: Version,
    max_depth: u16,
    context: *const anyopaque,
    read_record: *const fn (*const anyopaque, identity.GrantId) SourceError!Reply,
    missing: ?Request = null,

    pub const Record = types.Record;
    pub const Status = types.Status;
    pub const Version = struct { owner: identity.OwnerId, revisions: types.Version };
    pub const Request = struct { version: Version, id: identity.GrantId };
    pub const Reply = struct {
        version: Version,
        value: union(enum) { present: types.Record, absent: ResourceView.Absence, unloaded },
    };
    pub const SourceError = error{ ReadFailed, RecoveryRequired, RevisionConflict, InvalidRecord };
    pub const Error = SourceError || Terms.Error || error{ UnknownGrant, Paused, Revoked, OutOfScope, Denied };

    /// The source and borrowed term selections outlive each synchronous use.
    /// Sources return data at one revision, never policy verdicts or hidden I/O.
    /// Returned selections remain valid until the next grant lookup; resource
    /// source calls must not invalidate these grant borrows.
    pub fn init(version: Version, max_depth: u16, context: *const anyopaque, read_record: *const fn (*const anyopaque, identity.GrantId) SourceError!Reply) GrantView {
        return .{ .version = version, .max_depth = max_depth, .context = context, .read_record = read_record };
    }

    pub fn get(self: *GrantView, id: identity.GrantId) Error!types.Record {
        self.missing = null;
        if (id.owner != self.version.owner) return error.ForeignOwner;
        if (id.generation == 0) return error.UnknownGrant;
        const reply = try self.read_record(self.context, id);
        if (!std.meta.eql(reply.version, self.version)) return error.RevisionConflict;
        switch (reply.value) {
            .unloaded => {
                self.missing = .{ .version = self.version, .id = id };
                return error.RecordUnloaded;
            },
            .absent => |reason| return switch (reason) {
                .unknown => error.UnknownGrant,
                .gone => error.Gone,
            },
            .present => |record| {
                if (!record.id.eql(id) or @backingInt(record.revision) > @backingInt(self.version.revisions.grants)) return error.InvalidRecord;
                if (record.parent) |parent| {
                    if (parent.owner != id.owner or parent.generation == 0 or parent.eql(id)) return error.InvalidRecord;
                }
                return record;
            },
        }
    }

    pub const Ancestry = struct {
        view: *GrantView,
        cursor: ?identity.GrantId,
        depth: u32 = 0,

        pub fn next(self: *Ancestry) Error!?types.Record {
            const id = self.cursor orelse return null;
            if (self.depth > self.view.max_depth) return error.DepthLimit;
            const record = try self.view.get(id);
            self.cursor = record.parent;
            self.depth += 1;
            return record;
        }
    };

    pub fn ancestry(self: *GrantView, id: identity.GrantId) Ancestry {
        self.missing = null;
        return .{ .view = self, .cursor = id };
    }

    /// Revocation anywhere on the selected path wins over a temporary pause.
    /// Cyclic or missing ancestry cannot produce an active result.
    pub fn effectiveStatus(self: *GrantView, id: identity.GrantId) Error!types.Status {
        var result: types.Status = .active;
        var path = self.ancestry(id);
        while (try path.next()) |record| {
            if (record.status == .revoked) return .revoked;
            if (record.status == .paused) result = .paused;
        }
        return result;
    }

    pub fn requireActive(self: *GrantView, id: identity.GrantId) Error!void {
        switch (try self.effectiveStatus(id)) {
            .active => {},
            .paused => return error.Paused,
            .revoked => return error.Revoked,
        }
    }

    pub const Access = union(enum) {
        active: struct { ceiling: Policy.Value, configured: Policy.Value, effective: Policy.Value, delegation_depth: u16 },
        paused,
        revoked,
        out_of_scope,
    };

    /// Describes only this held path's access to one target. Inactive paths
    /// disclose a status alone, without ancestor identities or policy changes.
    /// The result is a snapshot, never admission for a later protected effect.
    pub fn describe(self: *GrantView, resources: *ResourceView, policy: *const Policy, id: identity.GrantId, target: identity.ResourceId) Error!Access {
        const effective = self.effectivePolicy(resources, policy, id, target) catch |err| switch (err) {
            error.Paused => return .paused,
            error.Revoked => return .revoked,
            error.OutOfScope => return .out_of_scope,
            else => return err,
        };
        const own = try self.get(id);
        return .{ .active = .{ .ceiling = own.ceiling.policy, .configured = own.configured.policy, .effective = effective, .delegation_depth = own.delegation_depth } };
    }

    /// Checks the full grant path and current containment. No result is a
    /// reusable admission across mutation, asynchronous work, or disclosure.
    pub fn require(self: *GrantView, resources: *ResourceView, policy: *const Policy, id: identity.GrantId, target: identity.ResourceId, requirement: Policy.Requirement) Error!void {
        const effective = try self.effectivePolicy(resources, policy, id, target);
        if (!try policy.allows(effective, requirement)) return error.Denied;
    }

    fn effectivePolicy(self: *GrantView, resources: *ResourceView, policy: *const Policy, id: identity.GrantId, target: identity.ResourceId) Error!Policy.Value {
        self.missing = null;
        resources.missing = null;
        if (resources.version.owner != self.version.owner or resources.version.revision != self.version.revisions.resources) return error.RevisionConflict;
        try self.requireActive(id);
        _ = try resources.get(target);
        var effective = (try self.get(id)).configured.policy;
        var path = self.ancestry(id);
        while (try path.next()) |record| {
            for ([_]Terms{ record.ceiling, record.configured }) |terms| {
                if (!try terms.scope.contains(resources, target)) return error.OutOfScope;
                effective = try policy.intersect(effective, terms.policy);
            }
        }
        return effective;
    }
};
