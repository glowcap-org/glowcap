//! CapTP lab ECS-lite: entities, components, resources, intents.
pub const world = @import("world.zig");
pub const components = @import("components.zig");
pub const resources = @import("resources.zig");
pub const intent = @import("intent.zig");

pub const Entity = world.Entity;
pub const World = world.World;
pub const Mode = resources.Mode;
pub const PanelFocus = resources.PanelFocus;
pub const Resources = resources.Resources;
pub const Intent = intent.Intent;
pub const IntentQueue = intent.Queue;

pub const max_entities: u16 = 256;

pub const LabWorld = struct {
    entities: World(max_entities),
    /// Screen rectangles, read back when the layout resolves a click.
    rect: components.Store(components.Rect, max_entities) = .{},
    res: Resources = .{},
    intents: IntentQueue = .{},

    // Named chrome (stable across frames).
    transcript_e: ?Entity = null,
    prompt_e: ?Entity = null,
    jump_chip_e: ?Entity = null,
    menu_e: ?Entity = null,

    pub fn init(gpa: std.mem.Allocator) LabWorld {
        return .{ .entities = World(max_entities).init(gpa) };
    }

    pub fn deinit(self: *LabWorld) void {
        self.entities.deinit();
    }
};

const std = @import("std");

test {
    _ = world;
    _ = intent;
}
