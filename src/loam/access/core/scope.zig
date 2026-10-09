//! Borrowed scope descriptions evaluated against one current resource graph.
//! Subtree scopes include future owned descendants. They cannot be narrowed
//! from a finite selection merely because today's subtree fits that selection.

const ResourceView = @import("resource_view.zig").ResourceView;
const ResourceId = @import("identity.zig").ResourceId;

/// Bounds validation work for an explicitly selected set of resources.
pub const max_scope_objects = 256;

pub const Scope = union(enum) {
    object: ResourceId,
    /// Strictly sorted, duplicate-free IDs, borrowed for the evaluation call.
    objects: []const ResourceId,
    owned_subtree: ResourceId,

    pub const Error = ResourceView.Error || error{ ScopeLimit, NonCanonicalScope };

    /// Visits only the selected objects or subtree root, never descendants.
    /// Each step validates its name and the selection's canonical order.
    pub const Targets = struct {
        scope: Scope,
        graph: *ResourceView,
        index: usize = 0,

        pub fn next(self: *Targets) Error!?ResourceView.Record {
            const id = switch (self.scope) {
                .object, .owned_subtree => |id| if (self.index == 0) id else return null,
                .objects => |ids| value: {
                    if (ids.len > max_scope_objects) return error.ScopeLimit;
                    if (self.index == ids.len) return null;
                    if (self.index != 0 and !ResourceId.lessThan(ids[self.index - 1], ids[self.index])) return error.NonCanonicalScope;
                    break :value ids[self.index];
                },
            };
            const record = try self.graph.get(id);
            self.index += 1;
            return record;
        }
    };

    pub fn targets(self: Scope, graph: *ResourceView) Targets {
        return .{ .scope = self, .graph = graph };
    }

    pub fn validate(self: Scope, graph: *ResourceView) Error!void {
        var selected = self.targets(graph);
        while (try selected.next()) |_| {}
    }

    /// Checks structural coverage only. Lifecycle, permissions, and retained
    /// upstream authority must also admit an application effect.
    pub fn contains(self: Scope, graph: *ResourceView, id: ResourceId) Error!bool {
        try self.validate(graph);
        _ = try graph.get(id);
        return self.containsValidated(graph, id);
    }

    /// Evaluate narrowing at this graph revision. Re-evaluate after graph
    /// changes; the result must not be cached as authority across a reparent.
    pub fn isSubsetOf(self: Scope, graph: *ResourceView, parent: Scope) Error!bool {
        try self.validate(graph);
        try parent.validate(graph);
        return switch (self) {
            .object => |id| parent.containsValidated(graph, id),
            .objects => |ids| blk: {
                for (ids) |id| if (!try parent.containsValidated(graph, id)) break :blk false;
                break :blk true;
            },
            .owned_subtree => |root| switch (parent) {
                .owned_subtree => |ancestor| graph.isDescendant(root, ancestor),
                .object, .objects => false,
            },
        };
    }

    fn containsValidated(self: Scope, graph: *ResourceView, id: ResourceId) ResourceView.Error!bool {
        return switch (self) {
            .object => |target| target.eql(id),
            .objects => |ids| blk: {
                for (ids) |target| if (target.eql(id)) break :blk true;
                break :blk false;
            },
            .owned_subtree => |root| graph.isDescendant(id, root),
        };
    }
};
