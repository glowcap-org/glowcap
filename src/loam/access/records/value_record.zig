//! Bounded passable receipt data uses durable identities for capability leaves.
const std = @import("std");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const WalkError = syrup.shared.WalkError;

pub const ValueRecord = struct {
    pub const max_bytes = 32 * 1024;
    pub const max_depth = 64;

    /// Scalar topology allowance for accepted values. Byte leaves include key
    /// and tag bytes. Capability IDs are emitted by this codec, not the caller.
    /// Measure shared writer fragments rather than duplicating Syrup widths.
    pub fn encodedSizeBound(comptime Value: type, values: usize, entries: usize, bytes: usize, capabilities: usize) !usize {
        var header: usize = 0;
        inline for (@typeInfo(Value).@"union".field_names) |name| {
            header = @max(header, try std.math.add(usize, try syrup.render.measureRecord(writeHeader, .{name}), 1));
        }
        const key_bytes = @sizeOf(@typeInfo(@TypeOf(loam.ObjectId.key)).@"fn".return_type.?);
        const maximum_leaf = @max(bytes, key_bytes);
        const prefix = (try s.byteStringSize(maximum_leaf)) - maximum_leaf;
        const count_bytes = try syrup.render.measureRecord(s.writePositiveInt, .{@as(u64, @intCast(values))});
        // Tagged values have both a leaf and a child count. Integer/float
        // payloads use eight bytes; big integers add one boolean to their leaf.
        const payload = try std.math.add(usize, prefix, @max(count_bytes, 8));
        var length = try std.math.mul(usize, values, try std.math.add(usize, header, payload));
        length = try std.math.add(usize, length, try std.math.mul(usize, entries, prefix));
        length = try std.math.add(usize, length, bytes);
        length = try std.math.add(usize, length, try std.math.mul(usize, capabilities, key_bytes));
        return @min(length, max_bytes);
    }

    fn writeHeader(sink: anytype, name: []const u8) WalkError!void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, name);
    }

    /// Context maps pre-retained capability leaves to their exact durable IDs.
    /// Both rendering passes are pure. Capture occurs before entering the codec.
    pub fn encode(allocator: std.mem.Allocator, value: anytype, context: anytype) ![]u8 {
        const length = try syrup.render.measureRecord(write, .{ value, context, @as(usize, 0) });
        if (length > max_bytes) return error.RecordTooLarge;
        const bytes = try allocator.alloc(u8, length);
        errdefer allocator.free(bytes);
        try syrup.render.renderRecordInto(bytes, write, .{ value, context, @as(usize, 0) });
        return bytes;
    }

    fn write(sink: anytype, value: anytype, context: anytype, depth: usize) WalkError!void {
        if (depth > max_depth) return error.FrameTooLarge;
        try writeHeader(sink, @tagName(value));
        switch (value) {
            .capability => |ref| try s.writeBytes(sink, &context.id(ref).key()),
            .bytes, .symbol, .string, .keyword => |bytes| try s.writeBytes(sink, bytes),
            .@"error" => |err| try s.writeBytes(sink, err.message),
            .void => {},
            .integer => |integer| {
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(i64, &bytes, integer, .big);
                try s.writeBytes(sink, &bytes);
            },
            .float64 => |float| {
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, @bitCast(float), .big);
                try s.writeBytes(sink, &bytes);
            },
            .boolean => |boolean| try s.writeBool(sink, boolean),
            .big_integer => |integer| {
                try s.writeBool(sink, integer.negative);
                try s.writeBytes(sink, integer.digits);
            },
            .list, .set => |items| {
                try s.writePositiveInt(sink, items.len);
                for (items) |item| try write(sink, item, context, depth + 1);
            },
            .tagged => |tagged| {
                try s.writeBytes(sink, tagged.tag);
                try s.writePositiveInt(sink, tagged.value.len);
                for (tagged.value) |item| try write(sink, item, context, depth + 1);
            },
            .@"struct" => |items| {
                try s.writePositiveInt(sink, items.len);
                for (items) |item| {
                    try s.writeBytes(sink, item.key);
                    try write(sink, item.value, context, depth + 1);
                }
            },
        }
        try s.endRecord(sink);
    }

    /// Returned byte leaves borrow bytes. The caller retains the receipt lease.
    /// Context restores only IDs retained by that receipt's strong edges.
    pub fn decode(comptime To: type, allocator: std.mem.Allocator, bytes: []const u8, context: anytype) !To {
        if (bytes.len > max_bytes) return error.RecordTooLarge;
        var cursor: usize = 0;
        const result = try read(To, allocator, bytes, &cursor, context, 0);
        errdefer free(allocator, result);
        try s.expectEnd(bytes, cursor);
        return result;
    }

    fn read(comptime To: type, allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, context: anytype, depth: usize) !To {
        if (depth > max_depth) return error.ValueTooDeep;
        try s.readByte(bytes, cursor, '<');
        const tag = try s.readSymbol(bytes, cursor);
        const result: To = result: {
            inline for (.{ "bytes", "symbol", "string", "keyword" }) |name| {
                if (std.mem.eql(u8, tag, name)) break :result @unionInit(To, name, try s.readBytesLimited(bytes, cursor, bytes.len));
            }
            if (std.mem.eql(u8, tag, "capability")) {
                const id = try loam.ObjectId.fromKey(try s.readBytesLimited(bytes, cursor, bytes.len));
                break :result .{ .capability = try context.restore(id) };
            }
            if (std.mem.eql(u8, tag, "void")) break :result .{ .void = {} };
            if (std.mem.eql(u8, tag, "boolean")) break :result .{ .boolean = try s.readBool(bytes, cursor) };
            if (std.mem.eql(u8, tag, "error")) break :result .{ .@"error" = .{ .message = try s.readBytesLimited(bytes, cursor, bytes.len) } };
            if (std.mem.eql(u8, tag, "integer") or std.mem.eql(u8, tag, "float64")) {
                const payload = try s.readBytesLimited(bytes, cursor, bytes.len);
                if (payload.len != 8) return error.InvalidRecord;
                const bits = std.mem.readInt(u64, payload[0..8], .big);
                break :result if (std.mem.eql(u8, tag, "integer")) .{ .integer = @bitCast(bits) } else .{ .float64 = @bitCast(bits) };
            }
            if (std.mem.eql(u8, tag, "big_integer")) break :result .{ .big_integer = .{ .negative = try s.readBool(bytes, cursor), .digits = try s.readBytesLimited(bytes, cursor, bytes.len) } };
            if (std.mem.eql(u8, tag, "list") or std.mem.eql(u8, tag, "set") or std.mem.eql(u8, tag, "tagged")) {
                const label = if (std.mem.eql(u8, tag, "tagged")) try s.readBytesLimited(bytes, cursor, bytes.len) else null;
                const items = try allocator.alloc(To, try count(bytes, cursor));
                var initialized: usize = 0;
                errdefer {
                    for (items[0..initialized]) |item| free(allocator, item);
                    allocator.free(items);
                }
                for (items) |*item| {
                    item.* = try read(To, allocator, bytes, cursor, context, depth + 1);
                    initialized += 1;
                }
                break :result if (label) |name| .{ .tagged = .{ .tag = name, .value = items } } else if (std.mem.eql(u8, tag, "list")) .{ .list = items } else .{ .set = items };
            }
            if (std.mem.eql(u8, tag, "struct")) {
                const Item = std.meta.Elem(@FieldType(To, "struct"));
                const items = try allocator.alloc(Item, try count(bytes, cursor));
                var initialized: usize = 0;
                errdefer {
                    for (items[0..initialized]) |item| free(allocator, item.value);
                    allocator.free(items);
                }
                for (items) |*item| {
                    item.* = .{ .key = try s.readBytesLimited(bytes, cursor, bytes.len), .value = try read(To, allocator, bytes, cursor, context, depth + 1) };
                    initialized += 1;
                }
                break :result .{ .@"struct" = items };
            }
            return error.InvalidRecord;
        };
        errdefer free(allocator, result);
        try s.readByte(bytes, cursor, '>');
        return result;
    }

    /// Frees container allocations. Byte leaves borrow the receipt. Restored
    /// capabilities remain owned by the context that restored them.
    pub fn free(allocator: std.mem.Allocator, value: anytype) void {
        switch (value) {
            .list, .set => |items| {
                for (items) |item| free(allocator, item);
                allocator.free(items);
            },
            .tagged => |tagged| {
                for (tagged.value) |item| free(allocator, item);
                allocator.free(tagged.value);
            },
            .@"struct" => |items| {
                for (items) |item| free(allocator, item.value);
                allocator.free(items);
            },
            else => {},
        }
    }

    fn count(bytes: []const u8, cursor: *usize) !usize {
        const length = try s.readPositiveInt(bytes, cursor);
        // Every child needs at least a complete record. Refuse before allocation.
        if (length > (bytes.len - cursor.*) / 3) return error.InvalidRecord;
        return @intCast(length);
    }
};
