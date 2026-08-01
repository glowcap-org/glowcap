//! Tiny entity world for the CapTP lab (ECS-lite). No Flecs.
const std = @import("std");

pub const Entity = enum(u32) {
    _,
    pub fn index(self: Entity) u32 {
        return @intFromEnum(self) & 0xffff;
    }
    pub fn generation(self: Entity) u16 {
        return @intCast((@intFromEnum(self) >> 16) & 0xffff);
    }
};

pub fn World(comptime max_entities: u16) type {
    return struct {
        const Self = @This();
        gpa: std.mem.Allocator,
        gen: [max_entities]u16 = [_]u16{0} ** max_entities,
        alive: [max_entities]bool = [_]bool{false} ** max_entities,
        free: std.ArrayList(u16) = .empty,
        next_slot: u16 = 0,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.free.deinit(self.gpa);
        }

        pub fn spawn(self: *Self) !Entity {
            const slot: u16 = if (self.free.pop()) |s| s else blk: {
                if (self.next_slot >= max_entities) return error.EntityCap;
                const s = self.next_slot;
                self.next_slot += 1;
                break :blk s;
            };
            self.alive[slot] = true;
            const g = self.gen[slot];
            return @enumFromInt((@as(u32, g) << 16) | slot);
        }
    };
}
