//! One bounded boundary copy for owning Values and plain model data.
//! Capabilities preserve opaque identity. Conversion to model data refuses them.
const std = @import("std");

/// The copy walk's error set is explicit because `copyAt`, `copySequence`,
/// and `copyItem` are mutually recursive, which the compiler refuses to
/// resolve as inferred sets. A borrowed view can fail to project.
pub const Error = error{ ValueTooDeep, UnsupportedValue, OwningReplyRequired, MalformedView } || std.mem.Allocator.Error;

pub fn copy(comptime To: type, allocator: std.mem.Allocator, value: anytype) Error!To {
    return copyAt(To, allocator, value, 0);
}

fn copyAt(comptime To: type, allocator: std.mem.Allocator, value: anytype, depth: usize) Error!To {
    if (depth > 64) return error.ValueTooDeep;
    switch (value) {
        inline else => |payload, tag| {
            const name = @tagName(tag);
            if (comptime std.mem.eql(u8, name, "reference") or std.mem.eql(u8, name, "handoff")) return error.UnsupportedValue;
            if (comptime std.mem.eql(u8, name, "capability")) {
                if (To == @import("value.zig").Value) return .{ .capability = payload };
                return error.OwningReplyRequired;
            } else if (comptime std.mem.eql(u8, name, "list") or std.mem.eql(u8, name, "set")) {
                return @unionInit(To, name, try copySequence(To, allocator, payload, depth));
            } else if (comptime std.mem.eql(u8, name, "tagged")) {
                const items = try copySequence(To, allocator, payload.value, depth);
                return .{ .tagged = .{ .tag = try allocator.dupe(u8, payload.tag), .value = items } };
            } else if (comptime std.mem.eql(u8, name, "struct")) {
                return .{ .@"struct" = try copySequence(std.meta.Elem(@FieldType(To, name)), allocator, payload, depth) };
            } else if (comptime std.mem.eql(u8, name, "integers")) {
                if (payload.len != 0 and depth == 64) return error.ValueTooDeep;
                // A run of integers copies as its words where the owner has
                // the arm, and as the list it means where it does not.
                if (comptime @hasField(To, "integers")) return .{ .integers = try allocator.dupe(i64, payload) };
                const items = try allocator.alloc(To, payload.len);
                for (payload, items) |word, *item| item.* = .{ .integer = word };
                return .{ .list = items };
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

fn measureAt(value: @import("value.zig").Value, depth: usize) !usize {
    if (depth > 64) return error.ValueTooDeep;
    var bytes: usize = 0;
    switch (value) {
        .bytes, .symbol, .string, .keyword => |leaf| bytes = leaf.len,
        .@"error" => |reason| bytes = reason.message.len,
        .big_integer => |big| bytes = big.digits.len,
        .integers => |words| {
            if (words.len != 0 and depth == 64) return error.ValueTooDeep;
            bytes = try std.math.mul(usize, words.len, @sizeOf(i64));
        },
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

/// Copy a list, set, tagged body, or struct entry list. An owned sequence is
/// a slice, and a borrowed one (`model.view.Args`, `model.view.StructEntries`)
/// is walked once through its iterator, so a handler's delivery copies into
/// an owner without materializing an owned tree first.
fn copySequence(comptime Item: type, allocator: std.mem.Allocator, sequence: anytype, depth: usize) Error![]Item {
    if (comptime @typeInfo(@TypeOf(sequence)) == .pointer) {
        const items = try allocator.alloc(Item, sequence.len);
        for (items, sequence) |*out, item| out.* = try copyItem(Item, allocator, item, depth);
        return items;
    }
    const count = try sequence.len();
    const items = try allocator.alloc(Item, count);
    var filled: usize = 0;
    var it = sequence.iterator();
    while (try it.next()) |item| {
        if (filled >= count) return error.MalformedView;
        items[filled] = try copyItem(Item, allocator, item, depth);
        filled += 1;
    }
    if (filled != count) return error.MalformedView;
    return items;
}

fn copyItem(comptime Item: type, allocator: std.mem.Allocator, item: anytype, depth: usize) Error!Item {
    if (comptime @hasField(Item, "key")) {
        return .{ .key = try allocator.dupe(u8, item.key), .value = try copyAt(@FieldType(Item, "value"), allocator, item.value, depth + 1) };
    }
    return copyAt(Item, allocator, item, depth + 1);
}
