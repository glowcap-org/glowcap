//! Typed restoration records above the portable graph. Local recipes retain
//! one actual target. Foreign recipes carry an established canonical sturdy URI.
const std = @import("std");
const core = @import("loam_core");
const Epoch = @import("live_epoch.zig").Epoch;

pub const max_attachment_name_bytes = 128;
pub const max_uri_bytes = 4096;

/// A payload is one tag byte and its body, the longest of which is a foreign URI.
pub const schema: core.Schema = .{ .id = 0x4c4f414d52454601, .version = 1, .max_payload = max_uri_bytes + 1, .max_edges = 1 };

pub const Recipe = union(enum) {
    local: struct { attachment: []const u8, target: core.ObjectId },
    foreign: []const u8,
    /// Data identifies a lifetime. Only the live scope holds actual authority.
    live: Epoch,

    pub fn decode(view: core.RecordView) !Recipe {
        if (view.schema != schema.id or view.schema_version != schema.version or view.payload.len < 2) return error.InvalidRecipe;
        return switch (view.payload[0]) {
            0 => blk: {
                if (view.payload.len > max_attachment_name_bytes + 1 or view.edge_count != 1) return error.InvalidRecipe;
                var edges = view.edges();
                const edge = edges.next().?;
                if (edge.strength != .strong or edge.restoration != .object) return error.InvalidRecipe;
                break :blk .{ .local = .{ .attachment = view.payload[1..], .target = edge.target } };
            },
            1 => if (view.edge_count == 0) .{ .foreign = view.payload[1..] } else error.InvalidRecipe,
            2 => blk: {
                if (view.payload.len != 25 or view.edge_count != 1) return error.InvalidRecipe;
                const edge = try view.edgeAt(0);
                if (edge.strength != .strong or edge.restoration != .object) return error.InvalidRecipe;
                const generation = std.mem.readInt(u64, view.payload[1..9], .big);
                const incarnation = std.mem.readInt(u64, view.payload[9..17], .big);
                const sequence = std.mem.readInt(u64, view.payload[17..25], .big);
                if (generation == 0 or incarnation == 0 or sequence == 0) return error.InvalidRecipe;
                break :blk .{ .live = .{ .object = edge.target, .generation = generation, .opening = .{ .incarnation = incarnation, .sequence = sequence } } };
            },
            else => error.InvalidRecipe,
        };
    }

    pub fn stage(self: Recipe, store: *core.Store, arena: std.mem.Allocator) !core.Edge {
        if (store.phase != .staging) return error.WrongPhase;
        var live_bytes: [24]u8 = undefined;
        const bytes = switch (self) {
            .local => |local| local.attachment,
            .foreign => |uri| uri,
            .live => |epoch| blk: {
                std.mem.writeInt(u64, live_bytes[0..8], epoch.generation, .big);
                std.mem.writeInt(u64, live_bytes[8..16], epoch.opening.incarnation, .big);
                std.mem.writeInt(u64, live_bytes[16..24], epoch.opening.sequence, .big);
                break :blk &live_bytes;
            },
        };
        const payload = try arena.alloc(u8, bytes.len + 1);
        payload[0] = switch (self) {
            .local => 0,
            .foreign => 1,
            .live => 2,
        };
        @memcpy(payload[1..], bytes);
        const id = try store.allocateId();
        const edges: []const core.Edge = switch (self) {
            .local => |local| &.{.{ .target = local.target }},
            .foreign => &.{},
            .live => |epoch| &.{.{ .target = epoch.object }},
        };
        try store.putCopying(.{ .id = id, .revision = 0, .schema = schema.id, .payload = payload, .edges = edges }, null);
        return .{ .target = id, .restoration = .recipe };
    }
};
