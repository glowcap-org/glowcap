//! Current grant records over a bounded synchronous source. An unloaded
//! ancestor produces a read demand, never an optimistic authority verdict.
//!
//! A source owns the storage of every record it returns and lends one record
//! at a time. The view refuses a lookup while a loan is open, so a borrowed
//! record can never be overwritten under its reader. A caller that needs a
//! record past the next lookup copies the fields it needs before releasing.
const std = @import("std");
const identity = @import("identity.zig");
const types = @import("grant_types.zig");
const ResourceView = @import("resource_view.zig").ResourceView;
const Policy = @import("policy.zig").Policy;
const Terms = @import("terms.zig").Terms;

pub const GrantView = struct {
    version: Version,
    max_depth: u16,
    source: Source,
    missing: ?Request = null,
    held: bool = false,

    pub const Record = types.Record;
    pub const Status = types.Status;
    pub const Version = struct { owner: identity.OwnerId, revisions: types.Version };
    pub const Request = struct { version: Version, id: identity.GrantId };
    pub const Reply = struct {
        version: Version,
        value: union(enum) { present: *const types.Record, absent: ResourceView.Absence, unloaded },
    };
    /// `RecordHeld` is a lookup while a loan is open. It stays on in every
    /// build mode because a stale borrow would be a stale authority verdict.
    pub const SourceError = error{ ReadFailed, RecoveryRequired, RevisionConflict, InvalidRecord, RecordHeld };
    pub const Error = SourceError || Terms.Error || error{ UnknownGrant, Paused, Revoked, OutOfScope, Denied };

    /// A source returns data at one revision, never policy verdicts or hidden
    /// I/O. `lend` returns a record the source keeps intact until `release`
    /// runs, and refuses with `RecordHeld` while an earlier loan is open.
    /// Resource lookups never disturb a lent grant record.
    pub const Source = struct {
        context: *const anyopaque,
        lend: *const fn (*const anyopaque, identity.GrantId) SourceError!Reply,
        /// Ends the open loan. Null when the source's records are stable, so
        /// no lookup can disturb a lent record and the view alone refuses
        /// reentrant lookups.
        release: ?*const fn (*const anyopaque) void = null,
    };

    pub fn init(version: Version, max_depth: u16, source: Source) GrantView {
        return .{ .version = version, .max_depth = max_depth, .source = source };
    }

    /// Borrow one current record. It stays valid until `release`, which must
    /// run before the next lookup through this view or its source.
    pub fn borrow(self: *GrantView, id: identity.GrantId) Error!*const types.Record {
        self.missing = null;
        if (self.held) return error.RecordHeld;
        if (id.owner != self.version.owner) return error.ForeignOwner;
        if (id.generation == 0) return error.UnknownGrant;
        const reply = try self.source.lend(self.source.context, id);
        // A lent record goes back on every refusal below.
        self.held = reply.value == .present;
        errdefer if (self.held) self.release();
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

    /// Return the borrowed record to its source. Releasing with no loan open
    /// is a caller bug.
    pub fn release(self: *GrantView) void {
        std.debug.assert(self.held);
        self.held = false;
        if (self.source.release) |end| end(self.source.context);
    }

    /// Walks from one grant to its root. Each record stays borrowed until the
    /// next step or `close`, so a loop that exits early closes the walk.
    pub const Ancestry = struct {
        view: *GrantView,
        cursor: ?identity.GrantId,
        depth: u32 = 0,
        holding: bool = false,

        pub fn next(self: *Ancestry) Error!?*const types.Record {
            self.close();
            const id = self.cursor orelse return null;
            if (self.depth > self.view.max_depth) return error.DepthLimit;
            const record = try self.view.borrow(id);
            self.holding = true;
            self.cursor = record.parent;
            self.depth += 1;
            return record;
        }

        pub fn close(self: *Ancestry) void {
            if (!self.holding) return;
            self.holding = false;
            self.view.release();
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
        defer path.close();
        while (try path.next()) |record| {
            result = result.worse(record.status);
            if (result == .revoked) return result;
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
        const effective = self.effectivePolicy(resources, policy, id, target, false) catch |err| switch (err) {
            error.Paused => return .paused,
            error.Revoked => return .revoked,
            error.OutOfScope => return .out_of_scope,
            else => return err,
        };
        const own = try self.borrow(id);
        defer self.release();
        return .{ .active = .{ .ceiling = own.ceiling.policy, .configured = own.configured.policy, .effective = effective.policy, .delegation_depth = own.delegation_depth } };
    }

    /// Checks the full grant path and current containment. No result is a
    /// reusable admission across mutation, asynchronous work, or disclosure.
    pub fn require(self: *GrantView, resources: *ResourceView, policy: *const Policy, id: identity.GrantId, target: identity.ResourceId, requirement: Policy.Requirement) Error!void {
        const effective = try self.effectivePolicy(resources, policy, id, target, false);
        if (!try policy.allowsSupported(effective.policy, effective.supported, requirement)) return error.Denied;
    }

    const Effective = struct { policy: Policy.Value, supported: u64 };

    /// Management may recover an issued endpoint while its use is paused.
    /// Revocation and current scope still refuse recovery. This grants no use.
    pub fn requireRecovery(self: *GrantView, resources: *ResourceView, policy: *const Policy, id: identity.GrantId, target: identity.ResourceId) Error!void {
        _ = try self.effectivePolicy(resources, policy, id, target, true);
    }

    /// The intersection of every ceiling and configured policy on the path,
    /// starting with the grant's own pair. Scope containment is checked on
    /// each record while it is borrowed, so no selection is copied.
    fn effectivePolicy(self: *GrantView, resources: *ResourceView, policy: *const Policy, id: identity.GrantId, target: identity.ResourceId, recovering: bool) Error!Effective {
        self.missing = null;
        resources.missing = null;
        if (resources.version.owner != self.version.owner or resources.version.revision != self.version.revisions.resources) return error.RevisionConflict;
        if (recovering) {
            if (try self.effectiveStatus(id) == .revoked) return error.Revoked;
        } else try self.requireActive(id);
        const target_record = try resources.get(target);
        var effective: ?Policy.Value = null;
        var path = self.ancestry(id);
        defer path.close();
        while (try path.next()) |record| {
            for ([_]*const Terms{ &record.ceiling, &record.configured }) |terms| {
                if (!try terms.scope.contains(resources, target)) return error.OutOfScope;
                effective = if (effective) |current| try policy.intersect(current, terms.policy) else terms.policy;
            }
        }
        // The walk begins at `id` itself, so its first step seeded the value.
        var value = effective.?;
        const supported = try policy.supported(target_record.kind, false);
        value.permissions &= supported;
        return .{ .policy = value, .supported = supported };
    }
};
