//! Scope and policy are independent restrictions on the same access path.
//! Public terms borrow a selection; retained grant terms own a bounded copy.

const std = @import("std");
const Scope = @import("scope.zig").Scope;
const ResourceView = @import("resource_view.zig").ResourceView;
const Policy = @import("policy.zig").Policy;
const ResourceId = @import("identity.zig").ResourceId;

pub const Terms = struct {
    scope: Scope,
    policy: Policy.Value,

    pub const Error = Scope.Error || Policy.Error;

    /// Compares the stored choices, independently of current scope coverage.
    pub fn eql(self: Terms, other: Terms) bool {
        if (!std.meta.eql(self.policy, other.policy)) return false;
        if (std.meta.activeTag(self.scope) != std.meta.activeTag(other.scope)) return false;
        return switch (self.scope) {
            .object => |id| id.eql(other.scope.object),
            .owned_subtree => |id| id.eql(other.scope.owned_subtree),
            .objects => |ids| blk: {
                if (ids.len != other.scope.objects.len) break :blk false;
                for (ids, other.scope.objects) |a, b| if (!a.eql(b)) break :blk false;
                break :blk true;
            },
        };
    }

    pub fn validate(self: Terms, graph: *ResourceView, policy: *const Policy) Error!void {
        try self.scope.validate(graph);
        try policy.validate(self.policy);
    }

    pub fn isSubsetOf(self: Terms, graph: *ResourceView, policy: *const Policy, parent: Terms) Error!bool {
        // Validate both halves before either can return a negative answer.
        try self.validate(graph, policy);
        try parent.validate(graph, policy);
        return try self.scope.isSubsetOf(graph, parent.scope) and try policy.isSubsetOf(self.policy, parent.policy);
    }
};

pub const StoredTerms = struct {
    terms: Terms,

    /// Caller validates before copying. Only a selected scope allocates, with
    /// the scope module's fixed selection limit bounding the retained copy.
    pub fn initCopying(allocator: std.mem.Allocator, terms: Terms) std.mem.Allocator.Error!StoredTerms {
        var result: StoredTerms = .{ .terms = terms };
        if (terms.scope == .objects) result.terms.scope = .{ .objects = try allocator.dupe(ResourceId, terms.scope.objects) };
        return result;
    }

    pub fn deinit(self: *StoredTerms, allocator: std.mem.Allocator) void {
        if (self.terms.scope == .objects) allocator.free(self.terms.scope.objects);
        self.* = undefined;
    }
};
