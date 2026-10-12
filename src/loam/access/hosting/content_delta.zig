//! An unchanged content callback needs no participant or change event.
const std = @import("std");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");
const Edit = @import("service.zig").ReferenceEdit;

pub const ContentDelta = struct {
    payload: []const u8,
    edges: []const hosting.references.Replacement,

    /// Encode validated recipes inside the same transaction as their fields.
    pub fn stageEdges(self: ContentDelta, store: *loam.Store, arena: std.mem.Allocator) ![]const loam.Edge {
        const edges = try arena.alloc(loam.Edge, self.edges.len);
        for (edges, self.edges) |*edge, replacement| edge.* = switch (replacement) {
            .edge => |value| value,
            .saved => |saved| try saved.stage(store),
        };
        return edges;
    }

    /// Payload borrows the pinned row or retained call arena. Edge output
    /// belongs to that arena and survives through the hosting transaction.
    pub fn prepare(arena: std.mem.Allocator, view: loam.RecordView, replacement: ?[]const u8, edits: []const Edit, appended: []const hosting.references.Replacement) !?ContentDelta {
        const payload = replacement orelse view.payload;
        var removed: usize = 0;
        for (edits, 0..) |edit, index| {
            if (edit.index >= view.edge_count) return error.NoSuchEdge;
            for (edits[0..index]) |prior| if (prior.index == edit.index) return error.DuplicateReferenceEdit;
            if (edit.replacement == null) removed += 1;
        }
        var changed = !std.mem.eql(u8, payload, view.payload) or removed != 0 or appended.len != 0;
        if (!changed) {
            var iterator = view.edges();
            var index: usize = 0;
            while (iterator.next()) |edge| : (index += 1) {
                for (edits) |edit| if (edit.index == index and (edit.replacement.? == .saved or !std.meta.eql(edit.replacement.?.edge, edge))) {
                    changed = true;
                    break;
                };
            }
        }
        if (!changed) return null;
        const edges = try arena.alloc(hosting.references.Replacement, view.edge_count - removed + appended.len);
        var iterator = view.edges();
        var input: usize = 0;
        var output: usize = 0;
        while (iterator.next()) |committed| : (input += 1) {
            const edge = for (edits) |edit| {
                if (edit.index == input) break edit.replacement;
            } else @as(?hosting.references.Replacement, .{ .edge = committed });
            if (edge) |value| {
                edges[output] = value;
                output += 1;
            }
        }
        @memcpy(edges[output..], appended);
        return .{ .payload = payload, .edges = edges };
    }
};
