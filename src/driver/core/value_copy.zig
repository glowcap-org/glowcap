//! One bounded boundary copy for owning Values and plain model data.
//! Capabilities preserve opaque identity; conversion to model data refuses them.
const std = @import("std");

pub fn copy(comptime To: type, allocator: std.mem.Allocator, value: anytype) anyerror!To {
    return copyAt(To, allocator, value, 0);
}

fn copyAt(comptime To: type, allocator: std.mem.Allocator, value: anytype, depth: usize) anyerror!To {
    if (depth > 64) return error.ValueTooDeep;
    switch (value) {
        inline else => |payload, tag| {
            const name = @tagName(tag);
            if (comptime std.mem.eql(u8, name, "reference") or std.mem.eql(u8, name, "handoff")) return error.UnsupportedValue;
            if (comptime std.mem.eql(u8, name, "capability")) {
                if (To == @import("value.zig").Value) return .{ .capability = payload };
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

/// Exact requested bytes of one copied root slice, including descendants and
/// leaves. Queue admission measures this shape before any payload is copied.
pub fn measureSlice(values: []const @import("value.zig").Value) !usize {
    var bytes = try std.math.mul(usize, values.len, @sizeOf(@import("value.zig").Value));
    for (values) |value| bytes = try std.math.add(usize, bytes, try measureAt(value, 0));
    return bytes;
}

fn measureAt(value: @import("value.zig").Value, depth: usize) anyerror!usize {
    if (depth > 64) return error.ValueTooDeep;
    var bytes: usize = 0;
    switch (value) {
        .bytes, .symbol, .string, .keyword => |leaf| bytes = leaf.len,
        .@"error" => |reason| bytes = reason.message.len,
        .big_integer => |big| bytes = big.digits.len,
        .list, .set => |items| {
            bytes = try std.math.mul(usize, items.len, @sizeOf(@import("value.zig").Value));
            for (items) |item| bytes = try std.math.add(usize, bytes, try measureAt(item, depth + 1));
        },
        .tagged => |tag| {
            bytes = try std.math.add(usize, tag.tag.len, try std.math.mul(usize, tag.value.len, @sizeOf(@import("value.zig").Value)));
            for (tag.value) |item| bytes = try std.math.add(usize, bytes, try measureAt(item, depth + 1));
        },
        .@"struct" => |items| {
            bytes = try std.math.mul(usize, items.len, @sizeOf(@import("value.zig").Value.StructEntry));
            for (items) |item| {
                bytes = try std.math.add(usize, bytes, item.key.len);
                bytes = try std.math.add(usize, bytes, try measureAt(item.value, depth + 1));
            }
        },
        else => {},
    }
    return bytes;
}
