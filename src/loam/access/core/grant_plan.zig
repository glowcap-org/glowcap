//! Grant mutation rules over current resource and grant views. A plan owns
//! changed terms, not an authority object or a second transaction executor.
const std = @import("std");
const types = @import("grant_types.zig");
const identity = @import("identity.zig");
const GrantView = @import("grant_view.zig").GrantView;
const ResourceView = @import("resource_view.zig").ResourceView;
const Terms = @import("terms.zig").Terms;
const StoredTerms = @import("terms.zig").StoredTerms;
const Policy = @import("policy.zig").Policy;
const GrantId = identity.GrantId;
const Error = types.Error;

const GrantCommand = union(enum) {
    issue_root: types.Issue,
    derive: struct { parent: GrantId, request: types.Issue },
    issue_control: struct { parent: GrantId, ceiling: Terms, request: types.Issue },
    set_policy: struct { grant: GrantId, terms: Terms },
    set_label: struct { grant: GrantId, label: types.Label },
    pause: GrantId,
    resume_access: GrantId,
    revoke: GrantId,
};
pub const Delta = union(enum) {
    /// The new row, whose selections the plan owns until commit adopts them.
    issue: types.Record,
    policy: StoredTerms,
    status: types.Status,
    label: types.Label,
};

pub const GrantPlan = struct {
    base: GrantView.Version,
    grant: GrantId,
    kind: types.Change.Kind,
    delta: Delta,

    pub const Command = GrantCommand;
    pub const Change = types.Change;

    /// The rows one commit writes. An edit's `record` carries the view's loan
    /// on the current row, so its unchanged selections stay valid until
    /// `release`. Issuance borrows nothing past this call.
    pub const Changes = struct {
        record: types.Record,
        /// Previous access-row revision, not its enclosing Loam record revision.
        expected: ?identity.Revision,
        parent: ?Parent,
        event: types.Change,
        borrowed: bool,

        /// The parent's inventory update, copied out of its row.
        pub const Parent = struct { id: GrantId, expected: identity.Revision, child_count: u32, revision: identity.Revision };

        pub fn release(self: Changes, grants: *GrantView) void {
            if (self.borrowed) grants.release();
        }
    };

    /// Trusted owner preparation. A fresh ID is reserved by the storage owner.
    /// Null denotes exhausted issuance capacity. The plan copies only changed
    /// selections. No lifecycle edit allocates and no event is published here.
    /// The owner must reserve/check the base revision through commit. This
    /// value neither locks storage nor proves authority to submit a command.
    pub fn prepareCopying(allocator: std.mem.Allocator, grants: *GrantView, resources: *ResourceView, policy: *const Policy, max_children: u32, fresh: ?GrantId, command: Command) Error!?GrantPlan {
        grants.missing = null;
        resources.missing = null;
        if (resources.version.owner != grants.version.owner or resources.version.revision != grants.version.revisions.resources) return error.RevisionConflict;
        return switch (command) {
            .issue_root => |request| try issue(allocator, grants, resources, policy, max_children, fresh, null, request, null),
            .derive => |request| try issue(allocator, grants, resources, policy, max_children, fresh, request.parent, request.request, null),
            .issue_control => |request| try issue(allocator, grants, resources, policy, max_children, fresh, request.parent, request.request, request.ceiling),
            .set_policy => |request| blk: {
                if (try grants.effectiveStatus(request.grant) == .revoked) return error.Revoked;
                {
                    const record = try grants.borrow(request.grant);
                    defer grants.release();
                    if (!try request.terms.isSubsetOf(resources, policy, record.ceiling)) return error.CeilingExceeded;
                    if (request.terms.eql(record.configured)) break :blk null;
                }
                _ = try nextRevision(grants);
                break :blk .{ .base = grants.version, .grant = request.grant, .kind = .policy_changed, .delta = .{ .policy = try StoredTerms.initCopying(allocator, request.terms) } };
            },
            .set_label => |request| blk: {
                try request.label.validate();
                if (try grants.effectiveStatus(request.grant) == .revoked) return error.Revoked;
                {
                    const record = try grants.borrow(request.grant);
                    defer grants.release();
                    if (record.label.eql(&request.label)) break :blk null;
                }
                _ = try nextRevision(grants);
                break :blk .{ .base = grants.version, .grant = request.grant, .kind = .label_changed, .delta = .{ .label = request.label } };
            },
            .pause => |id| try status(grants, id, .paused),
            .resume_access => |id| try status(grants, id, .active),
            .revoke => |id| try status(grants, id, .revoked),
        };
    }

    pub fn deinit(self: *GrantPlan, allocator: std.mem.Allocator) void {
        switch (self.delta) {
            .issue => |row| {
                row.ceiling.deinitOwned(allocator);
                row.configured.deinitOwned(allocator);
            },
            .policy => |*terms| terms.deinit(allocator),
            .status, .label => {},
        }
        self.* = undefined;
    }

    /// The proposed rows and event for atomic staging at the same view
    /// revision. The caller releases the result once it has encoded or
    /// copied the record.
    pub fn changes(self: *const GrantPlan, grants: *GrantView) Error!Changes {
        if (!std.meta.eql(self.base, grants.version)) return error.RevisionConflict;
        const revision = try nextRevision(grants);
        var parent: ?Changes.Parent = null;
        if (self.kind == .issued) if (self.kind.issued) |id| {
            const current = try grants.borrow(id);
            defer grants.release();
            parent = .{ .id = id, .expected = current.revision, .child_count = std.math.add(u32, current.child_count, 1) catch return error.ChildLimit, .revision = revision };
        };
        var record = switch (self.delta) {
            .issue => |row| row,
            else => (try grants.borrow(self.grant)).*,
        };
        const expected = if (self.delta == .issue) null else record.revision;
        switch (self.delta) {
            .issue => {},
            .policy => |replacement| record.configured = replacement.terms,
            .status => |value| record.status = value,
            .label => |value| record.label = value,
        }
        record.revision = revision;
        return .{
            .record = record,
            .expected = expected,
            .parent = parent,
            .event = .{ .version = .{ .resources = self.base.revisions.resources, .grants = revision }, .grant = self.grant, .kind = self.kind },
            .borrowed = self.delta != .issue,
        };
    }
};

fn issue(allocator: std.mem.Allocator, grants: *GrantView, resources: *ResourceView, policy: *const Policy, max_children: u32, fresh: ?GrantId, parent: ?GrantId, request: types.Issue, management: ?Terms) Error!GrantPlan {
    try request.label.validate();
    if (parent) |id| {
        if (management != null) {
            if (try grants.effectiveStatus(id) == .revoked) return error.Revoked;
        } else try grants.requireActive(id);
    }
    try request.ceiling.validate(resources, policy);
    if (!try request.configured.isSubsetOf(resources, policy, request.ceiling)) return error.CeilingExceeded;
    if (parent) |id| {
        {
            const source = try grants.borrow(id);
            defer grants.release();
            if (management) |ceiling| {
                if (!try request.ceiling.isSubsetOf(resources, policy, ceiling)) return error.CeilingExceeded;
                if (request.delegation_depth > grants.max_depth) return error.DepthLimit;
            } else if (source.delegation_depth == 0 or request.delegation_depth >= source.delegation_depth) return error.DelegationDenied;
            if (source.child_count >= max_children) return error.ChildLimit;
        }
        var path = grants.ancestry(id);
        defer path.close();
        while (try path.next()) |ancestor| {
            if (path.depth > grants.max_depth) return error.DepthLimit;
            if (!try request.ceiling.isSubsetOf(resources, policy, ancestor.ceiling) or
                (management == null and !try request.ceiling.isSubsetOf(resources, policy, ancestor.configured))) return error.CeilingExceeded;
        }
    } else if (request.delegation_depth > grants.max_depth) return error.DepthLimit;
    const id = fresh orelse return error.CapacityExceeded;
    if (id.owner != grants.version.owner) return error.ForeignOwner;
    if (id.generation == 0 or (parent != null and parent.?.eql(id))) return error.InvalidRecord;
    const revision = try nextRevision(grants);
    const ceiling = try Terms.initCopying(allocator, request.ceiling);
    errdefer ceiling.deinitOwned(allocator);
    const configured = try Terms.initCopying(allocator, request.configured);
    return .{
        .base = grants.version,
        .grant = id,
        .kind = .{ .issued = parent },
        .delta = .{ .issue = .{
            .label = request.label,
            .id = id,
            .parent = parent,
            .ceiling = ceiling,
            .configured = configured,
            .status = switch (request.initial_status) {
                .active => .active,
                .paused => .paused,
            },
            .revision = revision,
            .delegation_depth = request.delegation_depth,
            .child_count = 0,
        } },
    };
}

fn status(grants: *GrantView, id: GrantId, replacement: types.Status) Error!?GrantPlan {
    if (replacement != .revoked and try grants.effectiveStatus(id) == .revoked) return error.Revoked;
    const before = blk: {
        const record = try grants.borrow(id);
        defer grants.release();
        break :blk record.status;
    };
    if (before == replacement) return null;
    _ = try nextRevision(grants);
    return .{ .base = grants.version, .grant = id, .kind = .{ .status_changed = .{ .before = before, .after = replacement } }, .delta = .{ .status = replacement } };
}

fn nextRevision(grants: *const GrantView) Error!identity.Revision {
    return @fromBackingInt(std.math.add(u64, @backingInt(grants.version.revisions.grants), 1) catch return error.RevisionExhausted);
}
