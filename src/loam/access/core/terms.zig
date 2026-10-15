//! Scope and policy are independent restrictions on the same access path.
//! Public terms borrow a selection. Retained grant terms own a bounded copy.

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
        try policy.validate(self.policy);
        var supported: u64 = 0;
        var selected = self.scope.targets(graph);
        while (try selected.next()) |resource| supported |= try policy.supported(resource.kind, self.scope == .owned_subtree);
        if (self.policy.permissions & ~supported != 0) return error.InapplicablePermission;
    }

    pub fn isSubsetOf(self: Terms, graph: *ResourceView, policy: *const Policy, parent: Terms) Error!bool {
        // Validate both halves before either can return a negative answer.
        try self.validate(graph, policy);
        try parent.validate(graph, policy);
        return try self.scope.isSubsetOf(graph, parent.scope) and try policy.isSubsetOf(self.policy, parent.policy);
    }

    /// Caller validates before copying. Only a selected scope allocates, with
    /// the scope module's fixed selection limit bounding the retained copy.
    pub fn initCopying(allocator: std.mem.Allocator, terms: Terms) std.mem.Allocator.Error!Terms {
        var result = terms;
        if (terms.scope == .objects) result.scope = .{ .objects = try allocator.dupe(ResourceId, terms.scope.objects) };
        return result;
    }

    /// Frees the selection `initCopying` made.
    pub fn deinitOwned(self: Terms, allocator: std.mem.Allocator) void {
        if (self.scope == .objects) allocator.free(self.scope.objects);
    }
};

/// Terms whose selection the holder owns, where a field would otherwise read
/// as a borrow.
pub const StoredTerms = struct {
    terms: Terms,

    pub fn initCopying(allocator: std.mem.Allocator, terms: Terms) std.mem.Allocator.Error!StoredTerms {
        return .{ .terms = try Terms.initCopying(allocator, terms) };
    }

    pub fn deinit(self: *StoredTerms, allocator: std.mem.Allocator) void {
        self.terms.deinitOwned(allocator);
        self.* = undefined;
    }
};
