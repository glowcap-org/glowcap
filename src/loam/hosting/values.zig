//! Bounded copying between plain actor messages and owning Host values.
const std = @import("std");
const driver = @import("driver_core");

pub fn copy(comptime To: type, allocator: std.mem.Allocator, value: anytype) anyerror!To {
    return copyAt(To, allocator, value, 0);
}

fn copyAt(comptime To: type, allocator: std.mem.Allocator, value: anytype, depth: usize) anyerror!To {
    if (depth > 64) return error.ValueTooDeep;
    switch (value) {
        inline else => |payload, tag| {
            const name = @tagName(tag);
            if (comptime std.mem.eql(u8, name, "reference") or std.mem.eql(u8, name, "handoff")) return error.NotDurable;
            if (comptime std.mem.eql(u8, name, "capability")) {
                if (To == driver.Value) return .{ .capability = payload };
                return error.OwningReplyRequired;
            } else if (comptime std.mem.eql(u8, name, "list") or std.mem.eql(u8, name, "set")) {
                const items = try allocator.alloc(To, payload.len);
                for (items, payload) |*out, item| out.* = try copyAt(To, allocator, item, depth + 1);
                return @unionInit(To, name, items);
            } else if (comptime std.mem.eql(u8, name, "tagged")) {
                const items = try allocator.alloc(To, payload.value.len);
                for (items, payload.value) |*out, item| out.* = try copyAt(To, allocator, item, depth + 1);
                return .{ .tagged = .{ .tag = try allocator.dupe(u8, payload.tag), .value = items } };
            } else if (comptime std.mem.eql(u8, name, "struct")) {
                const Item = std.meta.Elem(@FieldType(To, name));
                const items = try allocator.alloc(Item, payload.len);
                for (items, payload) |*out, item| out.* = .{ .key = try allocator.dupe(u8, item.key), .value = try copyAt(To, allocator, item.value, depth + 1) };
                return .{ .@"struct" = items };
            } else if (comptime std.mem.eql(u8, name, "big_integer")) {
                var result = payload;
                result.digits = try allocator.dupe(u8, payload.digits);
                return .{ .big_integer = result };
            } else if (comptime std.mem.eql(u8, name, "error")) {
                return .{ .@"error" = .{ .message = try allocator.dupe(u8, payload.message) } };
            } else if (comptime @TypeOf(payload) == []const u8) {
                return @unionInit(To, name, try allocator.dupe(u8, payload));
            } else {
                return @unionInit(To, name, payload);
            }
        },
    }
}

pub fn plain(value: driver.Value) bool {
    value.forEachCapability({}, rejectCapability) catch return false;
    return true;
}

fn rejectCapability(_: void, _: driver.Capability) anyerror!void {
    return error.CapabilityFound;
}
