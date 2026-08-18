//! Owned Passable snapshots queued behind unresolved capability promises.
//!
//! Caller values are borrowed and the eventual destination session is not yet
//! known. This clone retains every nested Host capability while one arena owns
//! the remaining tree, giving the promise queue one rollback authority.

const std = @import("std");

const host_mod = @import("host.zig");
const value_mod = @import("value.zig");

const Host = host_mod.Host;

pub fn cloneValues(
    self: *Host,
    allocator: std.mem.Allocator,
    values: []const value_mod.Value,
    retained: *std.ArrayListUnmanaged(Host.StagedCapabilityRetain),
) anyerror![]value_mod.Value {
    const out = try allocator.alloc(value_mod.Value, values.len);
    for (values, 0..) |value, index|
        out[index] = try cloneValue(self, allocator, value, retained);
    return out;
}

fn cloneValue(
    self: *Host,
    allocator: std.mem.Allocator,
    value: value_mod.Value,
    retained: *std.ArrayListUnmanaged(Host.StagedCapabilityRetain),
) anyerror!value_mod.Value {
    return switch (value) {
        .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes) },
        .symbol => |symbol| .{ .symbol = try allocator.dupe(u8, symbol) },
        .capability => |ref| blk: {
            const target = self.capabilities.resolve(ref) orelse return error.UnknownCapability;
            const owned = try self.capabilities.retain(self.allocator, target);
            errdefer _ = self.capabilities.release(owned, 1) catch unreachable;
            try retained.append(allocator, .{ .ref = owned });
            break :blk .{ .capability = owned };
        },
        .@"error" => |reason| .{ .@"error" = .{
            .message = try allocator.dupe(u8, reason.message),
        } },
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
        .integer => |integer| .{ .integer = integer },
        .boolean => |boolean| .{ .boolean = boolean },
        .list => |items| .{ .list = try cloneValues(self, allocator, items, retained) },
        .void => .{ .void = {} },
        .float64 => |float| .{ .float64 = float },
        .set => |items| .{ .set = try cloneValues(self, allocator, items, retained) },
        .tagged => |tagged| .{ .tagged = .{
            .tag = try allocator.dupe(u8, tagged.tag),
            .value = try cloneValues(self, allocator, tagged.value, retained),
        } },
        .keyword => |keyword| .{ .keyword = try allocator.dupe(u8, keyword) },
        .big_integer => |big| .{ .big_integer = .{
            .negative = big.negative,
            .digits = try allocator.dupe(u8, big.digits),
        } },
        .@"struct" => |entries| blk: {
            const out = try allocator.alloc(value_mod.Value.StructEntry, entries.len);
            for (entries, 0..) |entry, index| out[index] = .{
                .key = try allocator.dupe(u8, entry.key),
                .value = try cloneValue(self, allocator, entry.value, retained),
            };
            break :blk .{ .@"struct" = out };
        },
    };
}

pub fn rollbackRetains(self: *Host, retained: []const Host.StagedCapabilityRetain) void {
    var index = retained.len;
    while (index != 0) {
        index -= 1;
        const retired = self.capabilities.release(retained[index].ref, 1) catch unreachable;
        std.debug.assert(retired == null);
    }
}
