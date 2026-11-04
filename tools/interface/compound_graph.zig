//! Bounded traversal of the Model-normalized reply graph, independent of target.
const std = @import("std");
const calls = @import("calls.zig");

pub fn compound(kind: calls.Type) bool {
    return kind == .list or kind == .tuple or kind == .record;
}

/// Compiler admission counts tuple/record containers and their inline fields.
/// Scalar and list slots count once. This is not a byte or schema cardinality limit.
pub const max_inline_structure: usize = 256;
pub const max_reply_work: usize = 65536;
const Node = struct { kind: calls.Type, minimum_work: [2]usize = .{ 0, 0 } };

pub const Graph = struct {
    a: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    scalar_types: std.ArrayList(calls.Type) = .empty,
    leaves: std.EnumSet(calls.Kind) = .{},
    remaining: usize = 65536,

    pub fn init(a: std.mem.Allocator, methods: []const calls.Named) !Graph {
        var self: Graph = .{ .a = a };
        errdefer self.deinit();
        for (methods) |method| if (method.call.effect != .tell) try self.collect(method.call.result);
        for (self.nodes.items) |node| {
            if (try self.minimumWork(node.kind, true) > max_inline_structure) return error.ResourceLimit;
        }
        return self;
    }

    pub fn deinit(self: *Graph) void {
        self.nodes.deinit(self.a);
        self.scalar_types.deinit(self.a);
    }

    pub fn spend(self: *Graph) !void {
        try self.spendWork(1);
    }

    pub fn spendWork(self: *Graph, work: usize) !void {
        if (work > self.remaining) return error.ResourceLimit;
        self.remaining -= work;
    }

    pub fn index(self: *Graph, kind: calls.Type) !?usize {
        try self.spendWork(self.nodes.items.len);
        for (self.nodes.items, 0..) |node, i| if (std.meta.eql(node.kind, kind)) return i;
        return null;
    }

    fn collect(self: *Graph, kind: calls.Type) !void {
        try self.spend();
        if (!compound(kind)) {
            try self.spendWork(self.scalar_types.items.len);
            var seen = false;
            for (self.scalar_types.items) |previous| if (std.meta.eql(previous, kind)) {
                seen = true;
            };
            if (!seen) try self.scalar_types.append(self.a, kind);
            self.leaves.insert(std.meta.activeTag(kind));
            return;
        }
        if (try self.index(kind) != null) return;
        try self.nodes.append(self.a, .{ .kind = kind });
        switch (kind) {
            .list => |list| try self.collect(list.element),
            .tuple => |tuple| for (tuple.fields) |field| try self.collect(field),
            .record => |record| for (record.fields) |field| try self.collect(field),
            else => unreachable,
        }
    }

    // Inline admission and owned projection count opaque Argument moves.
    // Borrowed views skip opaque leaves because they neither read nor move them.
    // Both scores share traversal and saturate before compiler emission.
    pub fn minimumWork(self: *Graph, kind: calls.Type, count_opaque: bool) !usize {
        try self.spend();
        const index_value = try self.index(kind) orelse return if (!count_opaque and kind == .value) 0 else 1;
        const score: usize = @intFromBool(count_opaque);
        if (self.nodes.items[index_value].minimum_work[score] != 0) return self.nodes.items[index_value].minimum_work[score];
        var work: usize = 1;
        const fields = switch (kind) {
            .tuple => |tuple| tuple.fields,
            .record => |record| record.fields,
            .list => &.{},
            else => unreachable,
        };
        for (fields) |field| {
            work += try self.minimumWork(field, count_opaque);
            if (work > max_inline_structure) {
                work = max_inline_structure + 1;
                break;
            }
        }
        self.nodes.items[index_value].minimum_work[score] = work;
        return work;
    }
};
