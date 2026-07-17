//! Component types for the CapTP lab scene.
const Entity = @import("world.zig").Entity;
const layout = @import("../layout.zig");

pub const Kind = enum {
    status,
    stage,
    transcript_viewport,
    block,
    rail,
    pane_header,
    pane_row,
    prompt,
    menu_row,
    jump_chip,
    modal,
};

/// Hit geometry in mouse/screen space (same type as layout helpers).
pub const Rect = layout.ScreenRect;

pub const Hit = struct {
    enabled: bool = true,
};

/// Dense component store keyed by entity index (generation checked by World).
pub fn Store(comptime T: type, comptime cap: u16) type {
    return struct {
        const Self = @This();
        slots: [cap]?T = [_]?T{null} ** cap,

        pub fn set(self: *Self, e: Entity, value: T) void {
            const i = e.index();
            if (i < cap) self.slots[i] = value;
        }

        pub fn get(self: *const Self, e: Entity) ?*const T {
            const i = e.index();
            if (i >= cap) return null;
            if (self.slots[i]) |*v| return v;
            return null;
        }

        pub fn getMut(self: *Self, e: Entity) ?*T {
            const i = e.index();
            if (i >= cap) return null;
            if (self.slots[i]) |*v| return v;
            return null;
        }

        pub fn remove(self: *Self, e: Entity) void {
            const i = e.index();
            if (i < cap) self.slots[i] = null;
        }
    };
}
