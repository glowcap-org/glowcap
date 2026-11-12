//! Tiny entity world for the CapTP lab (ECS-lite). No Flecs.
const std = @import("std");

pub const Entity = enum(u32) {
    _,
    pub fn index(self: Entity) u32 {
        return @backingInt(self) & 0xffff;
    }
};

pub fn World(comptime max_entities: u16) type {
    return struct {
        const Self = @This();
        gpa: std.mem.Allocator,
        next_slot: u16 = 0,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn spawn(self: *Self) !Entity {
            if (self.next_slot >= max_entities) return error.EntityCap;
            const slot = self.next_slot;
            self.next_slot += 1;
            return @fromBackingInt(slot);
        }
    };
}
