//! Typed restoration records above the portable graph. Local recipes retain
//! one actual target; foreign recipes carry an established canonical sturdy URI.
const std = @import("std");
const core = @import("loam_core");

pub const schema: core.Schema = .{ .id = 0x4c4f414d52454601, .version = 1, .max_payload = 4097, .max_edges = 1 };

pub const Recipe = union(enum) {
    local: struct { attachment: []const u8, target: core.ObjectId },
    foreign: []const u8,

    pub fn decode(view: core.RecordView) !Recipe {
        if (view.schema != schema.id or view.schema_version != schema.version or view.payload.len < 2) return error.InvalidRecipe;
        return switch (view.payload[0]) {
            0 => blk: {
                if (view.payload.len > 129 or view.edge_count != 1) return error.InvalidRecipe;
                var edges = view.edges();
                const edge = edges.next().?;
                if (edge.strength != .strong or edge.restoration != .object) return error.InvalidRecipe;
                break :blk .{ .local = .{ .attachment = view.payload[1..], .target = edge.target } };
            },
            1 => if (view.edge_count == 0) .{ .foreign = view.payload[1..] } else error.InvalidRecipe,
            else => error.InvalidRecipe,
        };
    }

    pub fn stage(self: Recipe, store: *core.Store, arena: std.mem.Allocator) !core.Edge {
        if (store.phase != .staging) return error.WrongPhase;
        const bytes = switch (self) {
            .local => |local| local.attachment,
            .foreign => |uri| uri,
        };
        const payload = try arena.alloc(u8, bytes.len + 1);
        payload[0] = switch (self) {
            .local => 0,
            .foreign => 1,
        };
        @memcpy(payload[1..], bytes);
        const id = try store.allocateId();
        const edges: []const core.Edge = switch (self) {
            .local => |local| &.{.{ .target = local.target }},
            .foreign => &.{},
        };
        try store.putCopying(.{ .id = id, .revision = 0, .schema = schema.id, .payload = payload, .edges = edges }, null);
        return .{ .target = id, .restoration = .recipe };
    }
};
